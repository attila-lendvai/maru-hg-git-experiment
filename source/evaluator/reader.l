;;; -*- mode: lisp; coding: us-ascii -*-

(require "source/streams-min.l")

(define-function is_blank (c)   (or      ( = ?   c)                     ; sp
                                         ( = ?\t c)                     ; ht
                                         ( = ?\n c)                     ; nl
                                         ( = ?\v c)                     ; vt
                                         ( = ?\f c)                     ; ff
                                         ( = ?\r c)))                   ; cr

(define-function is_alpha (c)   (or (and (<= ?a  c) (<= c ?z))          ; a b c d e f g h i j k l m n o p q r s t u v w x y z
                                    (and (<= ?A  c) (<= c ?Z))))        ; A B C D E F G H I J K L M N O P Q R S T U V W X Y Z

(define-function is_letter (c)  (or      ( = ?!  c)                     ; !
                                    (and (<= ?#  c) (<= c ?&))          ; # $ % &
                                    (and (<= ?*  c) (<= c ?/))          ; * + , - . /
                                         ( = ?:  c)                     ; :
                                    (and (<= ?<  c) (<= c ?Z))          ; < = > ?  @ A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
                                         ( = ?\\ c)                     ; \
                                         ( = ?^  c)                     ; ^
                                         ( = ?_  c)                     ; _
                                    (and (<= ?a  c) (<= c ?z))          ; a b c d e f g h i j k l m n o p q r s t u v w x y z
                                         ( = ?|  c)                     ; |
                                         ( = ?~  c)))                   ; ~

(define-function is_digit8  (c)     (and (<= ?0  c) (<= c ?7)))
(define-function is_digit10 (c)     (and (<= ?0  c) (<= c ?9)))
(define-function is_digit16 (c) (or (and (<= ?0  c) (<= c ?9))          ; 0 1 2 3 4 5 6 7 8 9
                                    (and (<= ?a  c) (<= c ?f))          ; a b c d e f
                                    (and (<= ?A  c) (<= c ?F))))        ; A B C D E F

(define-function digit_value (c)
  (cond
    ((and (<= ?0 c) (<= c ?9))  (- c ?0))
    ((and (<= ?a c) (<= c ?z))  (- c (- ?a 10)))
    ((and (<= ?A c) (<= c ?Z))  (- c (- ?A 10)))
    (else                       (fatal1 "illegal digit in character escape: %c" c))))

(define-function read/char (c stream)
  (if (= ?\\ c)
      (let ()
        (set c ($next stream))
        (case c
          (?a	?\a)
          (?b	?\b)
          (?e	?\e)
          (?f	?\f)
          (?n	?\n)
          (?r	?\r)
          (?t	?\t)
          (?v	?\v)
          (?u	(let ((a ($next stream))
                      (b ($next stream))
                      (c ($next stream))
                      (d ($next stream)))
                  (or (and (is_digit16 a)
                           (is_digit16 b)
                           (is_digit16 c)
                           (is_digit16 d))
                      (error "illegal character escape"))
                  (+ (bitwise-shift		(digit_value a) 24)
                     (+ (bitwise-shift		(digit_value b) 16)
                        (+ (bitwise-shift	(digit_value c)  8)
						(digit_value d))))))
          (?x	(let ((x 0))
                  (if (and (is_digit16 ($peek stream))
                           (or (set x (digit_value ($next stream)))
                               true)
                           (is_digit16 ($peek stream)))
                      (set x (+ (* x 16) (digit_value ($next stream))))
                    (error "illegal hexadecimal character escape"))
                  x))
          (else
           (cond
             ((and (<= ?0 c) (<= c ?7))
              (let ((x (digit_value c)))
                (if (and (is_digit8 ($peek stream))
                         (or (set x (+ (* x 8) (digit_value ($next stream))))
                             true)
                         (is_digit8 ($peek stream)))
                    (set x (+ (* x 8) (digit_value ($next stream))))
                  (error "illegal octal character escape"))
                x))

             ((or (is_alpha c) (is_digit10 c))
              (fatal1 "illegal character escape: \\%c" c))

             (else c)))))
    c))

(define-function read/number (c stream)
  (gc/let* ((buf (string 16)))
    (let ((negative?	false)
          (base		10))
      (if (= ?- c)
          (set negative? true)
        (string-append buf c))
      (while (is_digit10 (set c ($peek stream)))
        (string-append buf ($next stream)))
      ;; a 0x prefix?
      (when (and (= ?x c)
                 (= 1 (string-length buf)))
        ($next stream)
        (set base 16)
        (set (<string>-size buf) (box <long> 0)) ; TODO introduce API for this
        (while (is_digit16 ($peek stream))
          (string-append buf ($next stream))))
      (let ((result	(string->long* buf base)))
        (when (= +end+ result)
          (error "invalid number in source code, string->long* has failed for '"buf"' (it's printed without the sign here)"))
        (box <long> (if negative? (- result) result))))))

(define-function read/symbol (c stream)
  (gc/let* ((buf (string 16)))
    (assert (or (is_letter c) (is_digit10 c)))
    (string-append buf c)
    (while (and (set c ($peek stream))
                (or (is_letter c) (is_digit10 c)))
      (string-append buf ($next stream)))
    (string->symbol buf)))

(define-function read/string-literal (stream)
  ($next stream) ; drop opening "
  (gc/let* ((buf (string 8)))
    (let (c)
      (until (= ?\" (set c ($next stream)))
        (set c (read/char c stream))
        (when (= +end+ c)
          (error "unterminated string literal"))
        (string-append buf c)))
    buf))

(define read-nested) ; forward
(define read-toplevel) ; forward

(define-constant +end-of-list+ 0x22233455) ; just a unique constant

(define-function read/list (delim stream)
  ($next stream)                         ; drop opening paren
  (let* ((head (cons () ()))
         (tail head)
         (elt  ()))
    (gc/protect (head elt)
      (while (and (!= +end+ (set elt (read-nested stream)))
                  (!= +end-of-list+ elt)
                  (!= symbol/. elt))
        (set elt (cons elt ()))
        (set tail (put/tail tail elt)))
      (cond
        ((= symbol/. elt)
         (put/tail tail (read-toplevel stream))
         (unless (= delim ($next stream))
           (fatal1 "missing closing '%c' delimiter after ." delim))
         (get/tail head))
        ((and (= +end-of-list+ elt)
              (= delim ($next stream)))
         (get/tail head))
        (else
         (fatal1 "missing closing '%c' delimiter while reading list" delim))))))

(define-function read/quote (prefix stream)
  (gc/let* ((qobj (read-toplevel stream)))
    (when (= +end+ qobj)
      (error "EOF while reading quoted literal"))
    (set qobj (cons qobj ()))
    (set qobj (cons prefix qobj))
    qobj))

(define-function read-nested (stream)
  (while 1
    (let ((c ($peek stream)))
      (cond
        ((is_blank c)   ($next stream))
        ((= ?? c)       ($next stream) (return (box <long> (read/char ($next stream) stream))))
        ((= ?- c)       ($next stream)
                        (return (if (is_digit10 ($peek stream))
                                    (read/number c stream)
                                  (read/symbol c stream))))
        ((= ?\' c)      ($next stream) (return (read/quote symbol/quote stream)))
        ((= ?\` c)      ($next stream) (return (read/quote symbol/quasiquote stream)))
        ((= ?\, c)      ($next stream)
                        (return (let ((d ($peek stream)))
                                  (if (= ?@ d)
                                      (let ()
                                        ($next stream)
                                        (read/quote symbol/unquote-splicing stream))
                                    (read/quote symbol/unquote stream)))))
        ((is_letter c)  (return (read/symbol ($next stream) stream)))
        ((= ?\( c)      (return (read/list ?\) stream)))        ((= ?\) c) (return +end-of-list+))
        ((= ?\[ c)      (return (read/list ?\] stream)))        ((= ?\] c) (return +end-of-list+))
        ((= ?\{ c)      (return (read/list ?\} stream)))        ((= ?\} c) (return +end-of-list+))
        ((is_digit10 c) (return (read/number ($next stream) stream)))
        ((= ?\; c)      (while (and (!= ?\n (set c ($next stream)))
                                    (!= ?\r c)
                                    (!= +end+ c))))
        ((= ?\" c)      (return (read/string-literal stream)))
        ((= c +end+)    (return +end+))
        (else           (fatal1 "illegal character: %c" c))))))

(define-function read-toplevel (stream)
  (let ((c ($peek stream)))
    (cond
      ((= ?\( c)      (return (read/list ?\) stream)))
      ((= ?\[ c)      (return (read/list ?\] stream)))
      ((= ?\{ c)      (return (read/list ?\} stream)))
      ((or (= ?\) c)
           (= ?\] c)
           (= ?\} c))
       (error "unexpected close paren"))
      (else           (return (read-nested stream))))))

(define-primitive-function read (input)
  (read-toplevel input))
