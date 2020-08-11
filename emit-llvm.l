;;; -*- mode: lisp; coding: us-ascii -*-
;;;
;;; This is a compiler that emits LLVM IR text.
;;;
;;; Status: it should successfully compile eval.l into eval.s,
;;; that in turn can be compiled by the gcc toolchain into an executable eval binary.
;;;

;;; It can compile a subset of Maru.
;;;
;;; Limitations and peculiarities:
;;;   - no closures
;;;   - no variable number of args for functions
;;;   - only supports the following literals: Long, String (no lists, quoted literals, etc)
;;;   - string literals are compiled into .asciz, which means that they
;;;     are *not* tagged Maru objects on the heap; i.e. (t/print "foo") will
;;;     go astray because "foo" will be emitted as a null terminated string of
;;;     ascii bytes (instead of a Maru object of type <string>).
;;;   - probaby more
;;;   - see +special-operators+ and +special-forms+ for the list of specially
;;;     handled constructs
;;;
;;; Naming:
;;;   - EMIT: emit instructions into the output stream
;;;   - GEN:  like EMIT, but collect instructions into a buffer for later emission
;;;   - -foo- is an implicit var in the lexenv
;;;   - +foo+ is a constant
;;;   - *foo* is a global

(define *compiler-verbose* '()) ; NOTE this will break the output due to multiline string literals escape the ; prefixing

(define *ffi-type->llvm-type*
    (let ((word-size (slave-value slave:target-word-size/bits)))
      (cond
        ((= 32 word-size)
         '((slave:*		%ptr)
           (slave:int		i32)
           (slave:long		i32)
           (slave:unsigned-long	i32)
           (slave:size_t	i32)))
        ((= 64 word-size)
         '((slave:*		%ptr)
           (slave:int		i32)
           (slave:long		i64)
           (slave:unsigned-long	i64)
           (slave:size_t	i32))))))

(define-function ffi-type->llvm-type (type)
  (let ((entry (assq type *ffi-type->llvm-type*)))
    (if entry
        (second entry)
      type)))

(define-function llvm-type-bitsize (type)
  (assert (symbol? type))
  (cond
    ((= type '%ptr)	(slave-value slave:target-word-size/bits))
    ((= type 'void)	())
    (else
     (let ((entry	(assq type '((i64 . 64) (i32 . 32) (i16 . 16) (i8 . 8)))))
       (unless entry
         (error "llvm-type-bitsize: unexpected type "type))
       (cdr entry)))))

(define-function %llvm-escape (str char-needs-wrapping? legal-char? . with-zero)
  (let* ((length  (string-length str))
         (mangled (array)) ; strings don't auto-expand, so we need to use arrays here
         (index   0)
         (outdex  0)
         (putnext (lambda (c)
                    (set-array-at mangled outdex c)
                    (incr outdex)))
         (digit-for (lambda (c)
                      (if (< c 10)
                          (+ c ?0)
                        (+ c (- ?A 10)))))
         (wrap-result? ()))
    (while (< index length)
      (let ((c (string-at str index)))
        (when (char-needs-wrapping? c)
          (set wrap-result? 't))
        (if (legal-char? c)
            (putnext c)
          (putnext ?\\)
          (putnext (digit-for (>> c  4)))
          (putnext (digit-for (&  c 15)))))
      (incr index))
    (when with-zero
      (putnext ?\\)
      (putnext ?0)
      (putnext ?0))
    (when wrap-result?
      (putnext ?\")
      (array-insert mangled 0 ?\"))
    (array->string mangled)))

(define-function llvm/escape-string (str . with-zero)
  (%llvm-escape str
                (lambda _ 't) ; always wrap it in double quotes
                ;; TODO this felxibility may be unnecessary; duplicate code below
                (lambda (c)
                  (and (<= 32 c) (<= c 127)
                       (not (= ?\" c))
                       (not (= ?\\ c))))
                with-zero))

(define-function llvm/escape-identifier (name)
  (set name (symbol->string name))
  ;; we have two reserved keywords for the types
  (when (= name "ptr")  (set name "_ptr_"))
  (when (= name "word") (set name "_word_"))
  (%llvm-escape name
                (lambda (c)
                  (not (or (and (<= ?a c) (<= c ?z))
                           (and (<= ?A c) (<= c ?Z))
                           (and (<= ?0 c) (<= c ?9))
                           (memq c '(?- ?$ ?. ?_)))))
                (lambda (c)
                  (and (<= 32 c) (<= c 127)
                       (not (= ?\" c))
                       (not (= ?\\ c))))))

;;;
;;; OPERANDS
;;;
(define-function define-operand/make-setters (type-name fields)
  (if (pair? fields)
      (cons `(set (,(concat-symbol (concat-symbol type-name '-) (car fields)) self) ,(car fields))
            (define-operand/make-setters type-name (cdr fields)))))

(define-form define-operand (name fields . printing)
  (let ((type-name (symbol->type-name name)))
    (eval `(define-record ,type-name () ,fields))
    (eval `(define-function ,name ,fields
             (let ((self (new ,type-name)))
               ,@(define-operand/make-setters type-name fields)
               self)))
    `(define-method do-print ,type-name () (print ,@printing))))

(define-operand		GLOBAL		(name)		"@"(llvm/escape-identifier (<GLOBAL>-name self)))
(define-operand		LOCAL		(name)		"%"(llvm/escape-identifier (<LOCAL>-name self)))
(define-operand		LITERAL		(value)		(<LITERAL>-value self))
(define-operand		CONSTANT	(name value)	(<CONSTANT>-name self))
(define-operand		TEMP		(id)		"%"(llvm/escape-identifier (concat-string "t" (long->string (<TEMP>-id self)))))
(define-operand		LABEL		(name)		(llvm/escape-identifier (<LABEL>-name self)))
(define-function	UNIQUE-LABEL	()		(LABEL (unique-name "L")))

(define-function local? (obj)
  (= <LOCAL> (type-of obj)))

(define-function temp? (obj)
  (= <TEMP> (type-of obj)))

;;;
;;; COMPILER
;;;
(define-record <compiler> ()
  (level
   temp-counter
   reg-counter
   temps
   gen-buffer
   gen-buffer-index
   current-value ; the output of the previous-instruction
   ))

(define-function compiler (level)
  (make <compiler>
        (level			level)
        (temp-counter		0)
        (reg-counter		0)
        (gen-buffer		(array))
        (gen-buffer-index	-1)
        (current-value		())
        ))

;;; INSTRUCTIONS

(define-record <instruction> ()
  ;; TODO some of these slots are the same for all instances; they should reside on the type
  (regs
   has-input?
   n-regs
   produces-output?
   ))

(define-generic emit-instruction op-args
  (error "no emit-instruction defined for: " op-args ", types: " (map type-of op-args)))

(define-form emit (instr-name . args)
  `(%emit -c- ,instr-name (list ,@args)))

(define-function %emit (-c- factory args)
  (let* ((instr (factory)))
    (and *compiler-verbose* (println "; EMIT of "instr", args: " args)) ; TODO move this into emit-instruction?
    (apply emit-instruction (cons -c- (cons instr args)))))

(define-function %emit-form/mm-params (index types)
  (when (pair? types)
    (let ((param-name (string->symbol (concat-string "$" (long->string index)))))
      (cons (list (symbol->type-name (car types)) param-name)
            (%emit-form/mm-params (+ index 1) (cdr types))))))

(define-function %emit-form/reg-accessors (index)
  (when (>= index 0)
    ;; TODO name the last one as $output?
    (let ((var-name (string->symbol (concat-string "$reg" (long->string (+ index 1))))))
      (cons (list var-name () `((_) (list 'array-at '__regs__ ,index)))
            (%emit-form/reg-accessors (- index 1))))))

(define-function %define-instruction/emit-forms (instr-name n-regs type-name emit-forms)
  (when (pair? emit-forms)
    (let* ((emit-form (first emit-forms))
           (args (first emit-form))
           (body (rest emit-form)))
      (cons `(define-multimethod emit-instruction ((<compiler> -c-) (,type-name self) ,@(%emit-form/mm-params 1 args))
               ;;(println "; emitting " self)
               (let ((__regs__ (<instruction>-regs self)))
                 (with-forms (,@(%emit-form/reg-accessors (- n-regs 1)))
                   ,@body)))
            (%define-instruction/emit-forms instr-name n-regs type-name (rest emit-forms))))))

;; (define-instruction name (has-input? n-regs produces-output?) emit-forms)
(define-form define-instruction (instr-name reg-spec . emit-forms)
  (let ((has-input?		(first reg-spec))
        (n-regs			(or (second reg-spec) 0))
        (produces-output?	(third reg-spec))
        (type-name		(symbol->type-name instr-name)))
    `(let ()
       (define-record ,type-name <instruction> ())
       ;;(define-method do-print ,type-name () (print ,(symbol->string name)))
       (define-function ,instr-name ()
         (let ((i (new ,type-name)))
           (set (<instruction>-has-input? i)		',has-input?)
           (set (<instruction>-n-regs i)		',n-regs)
           (set (<instruction>-produces-output? i)	',produces-output?)
           i))
       ,@(%define-instruction/emit-forms instr-name n-regs type-name emit-forms))))

;;;
;;;
;;;
(define-function emit-llvm-fn-type (return-type param-types vararg?)
  (let ((first? 't))
    (print return-type " (")
    (list-do param-type (if vararg?
                            (concat-list param-types (list "..."))
                          param-types)
      (if first?
          (set first? ())
        (print ", "))
      (print (ffi-type->llvm-type param-type)))
    (print ")")))

(define-instruction COMMENT	()
  ;;((string)			(print "; ") (println $1))
  ((pair)			(print "; ") (apply println $1)))

(define-instruction INLINE	()
  ((string)			(print $1))
  ((pair)			(apply print $1)))

(define-instruction DEFINE	()
  ;; ((GLOBAL string)		(let ((length (+ 1 (string-length $2))))
  ;;       			  (println $1".c = private unnamed_addr constant [" length " x i8] c" (llvm/escape-string $2 't))
  ;;       			  (println $1"   = private unnamed_addr global %ptr bitcast([" length " x i8]* getelementptr([" length " x i8], [" length " x i8]* "$1".c) to %ptr)")))
  ((CONSTANT string)		(let ((length (+ 1 (string-length $2))))
				  (println $1" = private unnamed_addr constant [" length " x i8] c" (llvm/escape-string $2 't))))
  ((GLOBAL long)		(println $1" = global %ptr inttoptr (%word "$2" to %ptr)"))
  ((GLOBAL foreign-function)	(print "declare " (ffi-type->llvm-type (<foreign-function>-return-type $2)) " "$1"(")
				(let ((first? 't)
				      (param-types (<foreign-function>-parameter-types $2)))
                                  (list-do param-type (if (<foreign-function>-vararg? $2)
                                                          (concat-list param-types (list "..."))
                                                        param-types)
                                    (if first?
                                        (set first? ())
                                      (print ", "))
                                    (print (ffi-type->llvm-type param-type))))
				(println ")")))

(define-instruction ALLOCA	()
  ((TEMP)			(println "	"$1" = alloca %ptr")))

(define-instruction SEXT	(t 1 t)
  ((LOCAL symbol symbol)	(println "	"$reg1" = sext "$2" "$1" to "$3)))

(define-instruction INTTOPTR	(t 1 t)
  ((LOCAL symbol)		(println "	"$reg1" = inttoptr "$2" "$1" to %ptr")))

(define-instruction RET		(() 1 ())
  ((LOCAL)			(println "	ret %ptr "$1))
  ((TEMP)			(println "	"$reg1" = load %ptr, %ptr* "$1)
				(println "	ret %ptr "$reg1)))

(define-instruction LOAD	(() 1 t)
  ((LITERAL	long)		(println "	"$reg1" = inttoptr %word "$1" to %ptr"))
  ((TEMP	undefined)	(println "	"$reg1" = load %ptr, %ptr* "$1))
  ((GLOBAL	long)		(println "	"$reg1" = load %ptr, %ptr* "$1))
  ((GLOBAL	undefined)	(println "	"$reg1" = load %ptr, %ptr* "$1))
  ((GLOBAL	expr)		(let* ((defn		(<expr>-defn $2))
                                       (formal-params	(second defn))
                                       (param-types	(map (lambda _ '%ptr) formal-params)))
                                  (print "	"$reg1" = bitcast ")
                                  (emit-llvm-fn-type '%ptr param-types ())
                                  (println "* "$1" to %ptr"))))

(define-instruction STORE	(t () ())
  ((LOCAL TEMP)			(println "	store %ptr "$1", %ptr* "$2))
  ((LOCAL GLOBAL)		(println "	store %ptr "$1", %ptr* "$2)))

(define-instruction ADDR	(() 2 t)
  ((CONSTANT)			(let* ((str (<CONSTANT>-value $1))
                                       (length (+ 1 (string-length str))))
                                  (println "	"$reg2" = getelementptr [" length " x i8], [" length " x i8]* "(<CONSTANT>-name $1)", %word 0, %word 0")))
  ((TEMP)			(println "	"$reg1" = getelementptr %ptr, %ptr* "$1", %word 0")
				(println "	"$reg2" = bitcast %ptr* "$reg1" to %ptr"))
  ((LOCAL)			(println "	"$reg1" = getelementptr %ptr, %ptr* "$1", %word 0")
				(println "	"$reg2" = bitcast %ptr* "$reg1" to %ptr"))
  ((GLOBAL)			(println "	"$reg1" = getelementptr %ptr, %ptr* "$1", %word 0")
				(println "	"$reg2" = bitcast %ptr* "$reg1" to %ptr")))

(define-function emit-llvm-call (result-reg name args return-type param-types vararg?)
  (set return-type (ffi-type->llvm-type return-type))
  (set param-types (map ffi-type->llvm-type param-types))
  (let ((void? (= return-type 'slave:void)))
    (print "	")
    (unless void?
      (print result-reg" = " ))
    (print "call ")
    (if vararg?
        (emit-llvm-fn-type return-type param-types vararg?) ; LLVM only demands a full type when calling a vararg fn
      (print return-type))              ; short version
    (print " "name"(")
    (map (let ((first? 't))
           (lambda (arg)
             (let ((param-type (or (pop param-types) '%ptr)))
               ;; TODO FIXME this ... situation is messy
               (when (= param-type 'slave:...)
                 (set param-type '%ptr))
               (if first?
                   (set first? ())
                 (print ", "))
               (print param-type " " arg))))
         args)
    (println ")")))

(define-instruction CALL	(() 1 t)
  ((GLOBAL undefined)		(println "	"$reg1" = call %ptr "$1"()"))
  ((GLOBAL pair)		(let ((param-types (map (lambda _ '%ptr) $2)))
                                  (emit-llvm-call $reg1 $1 $2 '%ptr param-types ())))
  ((foreign-function undefined)	(emit-llvm-call $reg1
                                                (GLOBAL (<foreign-function>-name $1))
                                                ()
                                                (<foreign-function>-return-type $1)
                                                (<foreign-function>-parameter-types $1)
                                                (<foreign-function>-vararg? $1)))
  ((foreign-function pair)	(emit-llvm-call $reg1
                                                (GLOBAL (<foreign-function>-name $1))
                                                $2
                                                (<foreign-function>-return-type $1)
                                                (<foreign-function>-parameter-types $1)
                                                (<foreign-function>-vararg? $1))))

(define-instruction CALLPTR	(t 2 t)
  ;;((LOCAL  undefined)		(println "	"$reg1" = call %ptr "$1"()"))
  ((LOCAL pair)			(let ((param-types (map (lambda _ '%ptr) $2)))
                                  (print "	"$reg1" = bitcast %ptr "$1" to ")
                                  (emit-llvm-fn-type '%ptr param-types ())
                                  (println "*")
                                  (emit-llvm-call $reg2 $reg1 $2 '%ptr param-types ()))))

(define-instruction DEFLABEL	()
  ((LABEL)			(println $1":")))

(define-instruction BR		()
  ((LABEL)			(println "	br label %"$1)))

(define-instruction BRIF	(t 2 ())
  ((LOCAL LABEL LABEL)		(println "	"$reg1" = ptrtoint %ptr "$1" to %word")
				(println "	"$reg2" = icmp ne %word "$reg1", 0")
				(println "	br i1 "$reg2", label %"$2", label %"$3)))

(define-instruction NEG		(t 3 t)
  ((LOCAL)			(println "	"$reg1" = ptrtoint %ptr "$1" to %word")
				(println "	"$reg2" = sub nsw %word 0, "$reg1)
				(println "	"$reg3" = inttoptr %word "$reg2" to %ptr")))

(define-instruction NOT		(t 4 t)
  ((LOCAL)			(println "	"$reg1" = ptrtoint %ptr "$1" to %word")
				(println "	"$reg2" = icmp eq %word "$reg1", 0")
				(println "	"$reg3" = zext i1 "$reg2" to %word")
				(println "	"$reg4" = inttoptr %word "$reg3" to %ptr")))

(define-form define-cmp-instruction (instr-name llvm-comparator)
  `(define-instruction ,instr-name (t 4 t)
    ((LOCAL LOCAL)		(println "	"$reg1" = ptrtoint %ptr "$1" to %word")
				(println "	"$reg2" = ptrtoint %ptr "$2" to %word")
				(println "	"$reg3" = icmp " ,llvm-comparator " %word "$reg1", "$reg2)
				(println "	"$reg4" = inttoptr i1 "$reg3" to %ptr"))))

(define-cmp-instruction LT "slt")
(define-cmp-instruction LE "sle")
(define-cmp-instruction EQ "eq")
(define-cmp-instruction NE "ne")
(define-cmp-instruction GE "sge")
(define-cmp-instruction GT "sgt")

(define-form define-arithmetic-instruction (instr-name llvm-op)
  `(define-instruction ,instr-name (t 4 t)
    ((LOCAL LOCAL)		(println "	"$reg1" = ptrtoint %ptr "$1" to %word")
				(println "	"$reg2" = ptrtoint %ptr "$2" to %word")
				(println "	"$reg3" = " ,llvm-op " %word "$reg1", "$reg2)
				(println "	"$reg4" = inttoptr %word "$reg3" to %ptr"))))

(define-arithmetic-instruction ADD "add")
(define-arithmetic-instruction SUB "sub")
(define-arithmetic-instruction MUL "mul")
(define-arithmetic-instruction DIV "sdiv")

(define-arithmetic-instruction AND "and")
(define-arithmetic-instruction OR  "or")
(define-arithmetic-instruction XOR "xor")

(define-arithmetic-instruction SLA "shl")
(define-arithmetic-instruction SRA "ashr")

(define-instruction BYTE-AT	(t 5 t)
  ((LOCAL LOCAL)		(println "	"$reg1" = bitcast %ptr "$1" to [0 x i8]*")
				(println "	"$reg2" = ptrtoint %ptr "$2" to %word")
				(println "	"$reg3" = getelementptr [0 x i8], [0 x i8]* "$reg1", %word 0, %word "$reg2)
				(println "	"$reg4" = load i8, i8* "$reg3)
				(println "	"$reg5" = inttoptr i8 "$reg4" to %ptr")))

(define-instruction SET-BYTE-AT	(t 6 t)
  ((LOCAL LOCAL LOCAL)		(println "	"$reg1" = bitcast %ptr "$1" to [0 x i8]*")
				(println "	"$reg2" = ptrtoint %ptr "$2" to %word")
				(println "	"$reg3" = getelementptr [0 x i8], [0 x i8]* "$reg1", %word 0, %word "$reg2)
				(println "	"$reg4" = ptrtoint %ptr "$3" to i8")
				(println "	store i8 "$reg4", i8* "$reg3)
				(println "	"$reg5" = zext i8 "$reg4" to %word")
				(println "	"$reg6" = inttoptr %word "$reg5" to %ptr")))

(define-instruction OOP-AT	(t 4 t)
  ((LOCAL LOCAL)		(println "	"$reg1" = bitcast %ptr "$1" to [0 x %ptr]*")
				(println "	"$reg2" = ptrtoint %ptr "$2" to %word")
				(println "	"$reg3" = getelementptr [0 x %ptr], [0 x %ptr]* "$reg1", %word 0, %word "$reg2)
				(println "	"$reg4" = load %ptr, %ptr* "$reg3)))

(define-instruction SET-OOP-AT	(t 4 t)
  ((LOCAL LOCAL LOCAL)		(println "	"$reg1" = bitcast %ptr "$1" to [0 x %ptr]*")
				(println "	"$reg2" = ptrtoint %ptr "$2" to %word")
				(println "	"$reg3" = getelementptr [0 x %ptr], [0 x %ptr]* "$reg1", %word 0, %word "$reg2)
				(println "	store %ptr "$3", %ptr* "$reg3)
				(println "	"$reg4" = bitcast %ptr "$3" to %ptr")))

;;; COMPILER

(define-form gen (instr-name . args)
  `(%gen -c- ,instr-name (list ,@args)))

(define-function %gen (-c- factory args)
  (let ((instr (factory)))
    (and *compiler-verbose* (println "; GEN of "instr", args: " args))
    (when (<instruction>-has-input? instr)
      (push args (<compiler>-current-value -c-)))
    ;; instantiate the regs
    (set (<instruction>-regs instr)
         (let ((temps ()))
           (times-do (<instruction>-n-regs instr)
             (push temps (LOCAL (concat-string "r" (long->string (incr (<compiler>-reg-counter -c-)))))))
           (list->array temps)))
    ;; update current-value
    (when (<instruction>-produces-output? instr)
      (assert (> (<instruction>-n-regs instr) 0))
      (set (<compiler>-current-value -c-)
           (array-at (<instruction>-regs instr)
                     (- (<instruction>-n-regs instr) 1))))
    ;; save into the gen buffer
    (set (array-at (<compiler>-gen-buffer -c-)
                   (incr (<compiler>-gen-buffer-index -c-)))
         (cons instr args))
    instr))

(define-function previous-instruction (-c-)
  (let ((idx (<compiler>-gen-buffer-index -c-)))
    (when (< 0 idx)
      (first (array-at (<compiler>-gen-buffer -c-) idx)))))

(define-function emit-gen-buffer (comp)
  (for (i 0 (+ 1 (<compiler>-gen-buffer-index comp)))
    (let* ((entry (array-at (<compiler>-gen-buffer comp) i))
           (instr (first entry))
           (args (rest entry)))
      (and *compiler-verbose* (println "; EMIT-INSTRUCTION of "instr", args: "args))
      (apply emit-instruction (cons comp (cons instr args))))))

(define-function new-temp (comp)
  (TEMP (incr (<compiler>-temp-counter comp))))

(define-function alloc-temp (comp)
  (or (pop (<compiler>-temps comp))
      (new-temp comp)))

(define-function free-temp (comp temp)          (push (<compiler>-temps comp) temp))
(define-function free-temps (comp temps)        (list-do temp temps (free-temp comp temp)))

;;; COMPILE

(define-form comp (obj)
  `(let ((__obj__ ,obj))
     ,(and *compiler-verbose* `(println "; COMPILE of " __obj__))
     (compile __obj__ -c-)
     (<compiler>-current-value -c-)))

(define-selector compile)

(define-method compile <undefined>	(-c-)	(gen LOAD (LITERAL 0) 0))
(define-method compile <long>		(-c-)	(gen LOAD (LITERAL self) self))

(define-method compile <variable> (-c-)
  (let ((value (<variable>-value self)))
    (cond
      ((local? value)		(set (<compiler>-current-value -c-) value))
      ((temp? value)		(gen LOAD value ()))
      ((global-variable? self)	(gen LOAD (GLOBAL (<variable>-name self)) value))
      (else			(error "compile of <variable> failed for " (<variable>-name self) ", holding value " value)))))

(define-function compile/set (expr -c-)
  (let* ((var	(second expr))
         (value	(<variable>-value var)))
    (comp (third expr))
    (cond
      ;; NOTE the LLVM IR is SSA, locals cannot be written
      ((temp? value)		(gen STORE value))
      ((global-variable? var)	(gen STORE (GLOBAL (<variable>-name var))))
      (else			(error "compile/set failed for variable " (<variable>-name var) ", holding value " value)))))

(define-method compile <string> (-c-)
  (let ((const (CONSTANT (GLOBAL (unique-name "str")) self)))
    (emit DEFINE const self)
    (gen ADDR const)))

(define-function compile/prog-into-temp (prog -c-)
  (assert (pair? prog) "compile/prog-into-temp: prog is empty") ; against silently storing an uninitialized EAX while compiling e.g. (let (x) ...)
  (while (pair? prog)
    (comp (car prog))
    (set prog (cdr prog)))
  (let ((temp (alloc-temp -c-)))
    (gen STORE temp)
    temp))

(define-function compile/expr-into-temp (expr -c-)
  (comp expr)
  (let ((temp (alloc-temp -c-)))
    (gen STORE temp)
    temp))

(define-function compile/unary-operator (op args -c-)
  (comp (car args))
  (gen op))

(define-function compile/binary-operator (op args -c-)
  (comp (second args))
  (let ((arg2 (<compiler>-current-value -c-)))
    (comp (first args))
    (gen op arg2)))

(define-function compile/ternary-operator (op args -c-)
  (let ((tmp2 (let ()
                (comp (third  args))
                (<compiler>-current-value -c-)))
        (tmp1 (let ()
                (comp (second args))
                (<compiler>-current-value -c-))))
    (comp (first args))
    (gen op tmp1 tmp2)))

(define-function compile/let-binding (binding -c-)
  ;; we unconditionally initialize empty bindings to () to avoid hidden bugs,
  ;; at a small cost of initializing temp locations even when it wouldn't be necessary.
  (unless (pair? binding)
    (set binding (list binding ())))
  (unless (cdr binding)
    (set binding (list (car binding) ())))
  (let ((var (car binding))
        (prg (cdr binding)))
    (assert (= (type-of var) <variable>) "compile/let-binding: encountered a non-variable: " var)
    (set (<variable>-value var) (compile/prog-into-temp prg -c-))))

(define-function compile/let (expr -c-)
  (let ((temps (map-with compile/let-binding (third expr) -c-)))
    (list-do form (cdddr expr)
      (comp form))
    (list-do temp temps
      (free-temp -c- temp))))

(define-function %compile/and-or (op expr -c-)
  (let ((lend	(UNIQUE-LABEL))
        (retval	(alloc-temp -c-)))
    (gen LOAD (LITERAL (cond
                         ((= op 'and) (slave-value slave:target-boolean/true))
                         ((= op 'or)  (slave-value slave:target-boolean/false))))
         0) ; just for the type dispatch
    (gen STORE retval)
    (while (set expr (rest expr))
      (let ((value-reg (comp (first expr))))
        (gen STORE retval)
        (gen LOAD (LITERAL 0) 0)
        (gen EQ value-reg))
      (let ((lcont (UNIQUE-LABEL)))
        (cond
          ((= op 'and) (gen BRIF lend  lcont))
          ((= op 'or)  (gen BRIF lcont lend)))
        (gen DEFLABEL lcont)))
    (gen BR lend)
    (gen DEFLABEL lend)
    (gen LOAD retval ())
    (free-temp -c- retval)))

(define-function compile/and (expr -c-)
  (%compile/and-or 'and expr -c-))

(define-function compile/or (expr -c-)
  (%compile/and-or 'or  expr -c-))

(define-function compile/if (expr -c-)
  (let ((ltrue	(UNIQUE-LABEL))
        (lfalse	(UNIQUE-LABEL))
        (lend	(UNIQUE-LABEL))
        (retval	(alloc-temp -c-)))
    (comp (second expr))                ; condition
    (gen BRIF ltrue lfalse)

    ;; true
    (gen DEFLABEL ltrue)
    (comp (third expr))
    (gen STORE retval)
    (gen BR lend)

    ;; false
    (gen DEFLABEL lfalse)
    (let ((else-prg (cdddr expr)))
      (if else-prg
          (list-do stmt else-prg
            (comp stmt))
        (gen LOAD (LITERAL 0) 0))
      (gen STORE retval))
    (gen BR lend)

    ;; end
    (gen DEFLABEL lend)
    (gen LOAD retval ())
    (free-temp -c- retval)))

(define-function compile/while (expr -c-)
  ;; TODO double-check the return value semantics
  (let ((lbody	(UNIQUE-LABEL))
        (ltest	(UNIQUE-LABEL))
        (lend	(UNIQUE-LABEL)))
    (gen BR ltest)

    (gen DEFLABEL lbody)
    (list-do stmt (cddr expr)
      (and stmt (comp stmt)))
    (gen BR ltest)

    (gen DEFLABEL ltest)
    (comp (second expr))

    (gen BRIF lbody lend)

    (gen DEFLABEL lend)))

(define-function compile/lambda (expr comp)
  (error "gen: lambda forms are not supported"))

(define-function compile/return (form -c-)
  (assert (<= (list-length form) 2))
  (let ((value (second form)))
    (comp value)
    (gen RET (<compiler>-current-value -c-))))

(define-function compile/address-of (expr -c-)
  (let ((var (second expr)))
    (or (variable? var) (error "address-of: non-variable argument: "var))
    (let ((val (<variable>-value var)))
      (cond
        ((global-variable? var)
         (gen ADDR (GLOBAL (<variable>-name var))))
        (else
         (gen ADDR val))))))

(define +special-forms+ (list
  (cons (slave-value slave:let)		compile/let)
  (cons (slave-value slave:and)		compile/and)
  (cons (slave-value slave:or)		compile/or)
  (cons (slave-value slave:if)		compile/if)
  (cons (slave-value slave:while)	compile/while)
  (cons (slave-value slave:set)		compile/set)
  (cons (slave-value slave:lambda)	compile/lambda)
  (cons (slave-value slave:return)	compile/return)
  (cons (slave-value slave:address-of)	compile/address-of)))

;; a vector of assoc lists indexed by operator arity
(define +special-operators+
    (let ((table
           `(;; nullary
             ()
             ;; unary
             ((slave:-  ,NEG) (slave:not ,NOT))
             ;; binary
             ((slave:+  ,ADD) (slave:-   ,SUB) (slave:* ,MUL) (slave:/ ,DIV)
              (slave:&  ,AND) (slave:|   ,OR ) (slave:^ ,XOR)
              (slave:<  ,LT ) (slave:<=  ,LE ) (slave:= ,EQ ) (slave:!= ,NE) (slave:>= ,GE) (slave:> ,GT)
              (slave:<< ,SLA) (slave:>>  ,SRA)
              (slave:oop-at ,OOP-AT)
              (slave:string-at ,BYTE-AT))
             ;; ternary
             ((slave:set-oop-at ,SET-OOP-AT)
              (slave:set-string-at ,SET-BYTE-AT)
              ))))
      (list->array
       (map (lambda (arity-line)
              (map (lambda (entry)
                     (let* ((op-name (car entry))
                            (op (eval-in-module slave op-name)))
                       ;; NOTE this is not (slave-value slave:<subr>), because it's the eval.exe of the
                       ;; previous stage that instantiates these subr's, and it instantiates them
                       ;; with the type that is encoded into the executable (which should be in sync
                       ;; with the definitions in the boot.l of that stage, which in turn is what we
                       ;; see here at runtime).
                       (assert (= (type-of op) <subr>) "an operator is not (= (type-of op) <subr>)")
                       (cons op (cdr entry))))
                   arity-line))
            table))))

(define +operator-compilers+ (list->array (list () compile/unary-operator compile/binary-operator compile/ternary-operator)))

(define-method compile <pair> (-c-)
  (let* ((op		(first self))
         (op-is-a-var	(variable? op))
         (args		(rest self))
         (arity		(list-length args))
         (handler	()))
    (cond
      ((set handler (and op-is-a-var
                         (second (assq (<variable>-value op) (array-at +special-operators+ arity)))))
       ((array-at +operator-compilers+ arity) handler args -c-))
      ((set handler (cdr (assq op +special-forms+)))
       (handler self -c-))
      (else
       (let ((arg-regs (map (lambda (arg)
                              (and *compiler-verbose* (gen COMMENT (list "arg " arg)))
                              (comp arg)
                              (<compiler>-current-value -c-))
                            args)))
         (cond
           ((and op-is-a-var
                 (global-variable? op))
            (let ((value (<variable>-value op))
                  (n-params ()))
              (cond
                ((expr? value)
                 (gen CALL (GLOBAL (<variable>-name op)) arg-regs)
                 (set n-params (<expr>-n-required-parameters value)))
                ((= (type-of value) <foreign-function>)
                 (let ((param-types	(<foreign-function>-parameter-types value)))
                   (and *compiler-verbose* (gen COMMENT (list "	casting FFI args")))
                   ;; for FFI calls we need to cast the non-pointer llvm args
                   ;; using ptrtoint to the specific llvm type.
                   (let ((param-type	())
                         (new-arg-regs	())
                         (arg		())
                         (arg-lst	arg-regs)
                         (param-lst	param-types))
                     (while (set arg (pop arg-lst))
                       (set param-type (ffi-type->llvm-type (pop param-lst)))
                       (if (or (= ()    param-type) ; vararg calls have more args than formals
                               (= '%ptr param-type))
                           (push new-arg-regs arg)
                         (let ((cast-reg (LOCAL (concat-string "ffi-cast" (long->string (incr (<compiler>-reg-counter -c-)))))))
                           ;; TODO check for value range issues?
                           (gen INLINE (list "	"cast-reg" = ptrtoint %ptr "arg" to "param-type"\n"))
                           (push new-arg-regs cast-reg))))
                     ;; gen the call itself
                     (gen CALL value (list-reverse! new-arg-regs)))
                   ;; convert return value
                   (let ((return-type (ffi-type->llvm-type (<foreign-function>-return-type value))))
                     (cond
                       ((= '%ptr return-type)) ; all good
                       ((= 'slave:void return-type)
                        (and *compiler-verbose* (gen COMMENT (list "	void FFI call return value")))
                        (gen LOAD (LITERAL 0) 0))
                       (else
                        (let ((bitsize		(llvm-type-bitsize return-type))
                              (target-word-size	(slave-value slave:target-word-size/bits)))
                          (cond
                            ((< bitsize target-word-size)	(gen SEXT return-type '%word))
                            ((> bitsize target-word-size)	(error "This shouldn't happen: (> bitsize target-word-size) for FFI type " return-type))))
                        (gen INTTOPTR '%word))))
                   (unless (<foreign-function>-vararg? value)
                     (set n-params (list-length param-types)))))
                (else
                 (error "Don't know how to emit call to global value "value", in variable "op)))
              (when (and n-params
                         (not (= n-params arity)))
                (error "compile: calling " value
                       " with the wrong number of arguments: " args
                       ", while expecting " n-params))))
           (else
            (comp op)
            (gen CALLPTR arg-regs))))))))

;;; COMPILE-DEFINITION

(define-selector compile-definition)

(define-method compile-definition <undefined> (name comp)
  (compile-definition 0 name comp))

;; (define-method compile-definition <type> (name comp)
;;   ;; type definitions produce no level-shifted artifacts
;;   )

(define-method compile-definition <long> (name -c-)
  (gen DEFINE (GLOBAL name) self))

(define-method compile-definition <foreign-function> (name -c-)
  (emit DEFINE (GLOBAL (<foreign-function>-name self)) self))

(define-method compile-definition <form> (name -c-)
  (gen COMMENT (list "form "name)))

(define-function emit/function-prologue (name params)
  (print "define %ptr "name"(")
  (let ((first? 't))
    (list-do param params
      (if first?
          (set first? ())
        (print ", "))
      (print "%ptr ")
      (print param)))
  (println ") {"))

(define-function emit/function-epilogue ()
  (println "}"))

;; Shall we map function directly to LLVM IR function params?
;; NOTE: They are read-only, and as of now eval.l violates this assumption.
(define-constant +function-parameters-are-read-only+ ())

(define-method compile-definition <expr> (name parent-comp)
  (let* ((defn		(<expr>-defn self))
         (formal-params	(second defn))
         (body		(cddr defn))
         (-c-		(compiler (+ 1 (<compiler>-level parent-comp))))
         (init-param	(lambda (var)
                          (set (<variable>-value var)
                               (if +function-parameters-are-read-only+
                                   (LOCAL (<variable>-name var))
                                 (alloc-temp -c-)))))
         (params	(map init-param formal-params))
         (param-decls	(map (lambda (var)
                               (LOCAL (<variable>-name var)))
                             formal-params)))
    (list-do e body
      (comp e))

    (emit/function-prologue (GLOBAL name) param-decls)

    (unless +function-parameters-are-read-only+
      (free-temps -c- params))

    ;; all temps must be free-temp'ed properly at this point.
    (map (lambda (tmp)
           (emit ALLOCA tmp))
         (<compiler>-temps -c-))

    ;; store the parameters in the temps
    (unless +function-parameters-are-read-only+
      (map (lambda (local temp)
             (emit STORE local temp))
           param-decls params))

    ;; emit the body from the gen buffer
    (emit-gen-buffer -c-)

    ;; make sure we finish off with a ret
    (unless (= <RET> (type-of (previous-instruction -c-)))
      (emit RET (or (<compiler>-current-value -c-)
                    (LITERAL "null"))))
    (emit/function-epilogue)))

;;;
;;; compilation unit
;;;
(define-function compile-env (env)
  (warn "begin compiling\n")
  (let* ((vars  (<env>-bindings env))
         (-c-  (compiler 0)))
    (let (;(target-triplet	(slave-value slave:target-triplet))
          (word-size		(slave-value slave:target-word-size/bits)))
      (warn "\nCompiling for word size: " word-size " bits\n\n")
      ;;(assert (string?	target-triplet))
      (assert (long?	word-size))
      ;; our output is less specific, so allow the makefile, or whoever builds the
      ;; bitcode output to chose the proper target triplet.
      ;;(emit INLINE (concat-strings "target triple = \"" target-triplet "\"\n"))
      (emit INLINE (concat-strings "%word = type i" (long->string word-size) "\n")))
    (emit INLINE "%ptr = type i8*\n")
    (for (i 0 (array-length vars))
      (let* ((var   (array-at vars i))
             (name  (<variable>-name  var))
             (value (<variable>-value var)))
        (and *compiler-verbose* (emit COMMENT (list "defn " name)))
        (warn name ", ")
        (compile-definition value name -c-)))
    (warn "\n")
    (emit-gen-buffer -c-)))