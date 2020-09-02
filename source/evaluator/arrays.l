;;; -*- mode: lisp; coding: us-ascii -*-

(define-form define-vector-like (basename elements-are-opaque? accessor copier element-size-in-bytes)
  (let ((vector-type (concat-symbols '< basename '>))
        (length-name (concat-symbols 'k/ basename '-length))
        (getter-name (concat-symbols 'k/ basename '-at))
        (setter-name (concat-symbols 'set-k/ basename '-at))
        (append-name (concat-symbols 'k/ basename '-append))
        (insert-name (concat-symbols 'k/ basename '-insert))
        (zeroed-name (concat-symbols 'k/ basename '-ensure-zero-terminated)))
    `(let ()
       (define-function ,length-name (obj)
         (get/long (get ,vector-type size obj)))

       (define-function ,getter-name (obj idx)
         (safety 1 (or (and (is ,vector-type obj) (<= 0 idx)) (fatal2 ,(concat-string (symbol->string getter-name) ": called with object of type %d, and index %d") (get/type obj) idx)))
         (let ((elements (get ,vector-type _bits obj))
               (size     (,length-name obj)))
           (and (< idx size)
                (,accessor elements idx))))

       (define-function ,setter-name (obj idx val)
         (safety 1 (or (and (is ,vector-type obj) (<= 0 idx)) (fatal2 ,(concat-string (symbol->string setter-name) ": called with object of type %d, and index %d") (get/type obj) idx)))
         (let* ((elements	(get ,vector-type _bits obj))
                (size		(get/long (get ,vector-type size obj)))
                (capacity	(if elements
                                    (/ (gc/object-size elements)
                                       ,element-size-in-bytes)
                                  0)))
           (unless (< idx capacity)
             (when (= 0 capacity)
               (set capacity 1))
             (while (not (< idx capacity))
               (set capacity (* capacity 2)))
             (gc/let* ((new-elements (,(if elements-are-opaque? 'gc/allocate-opaque 'gc/allocate)
                                       <data> (* capacity ,element-size-in-bytes)))) ; note: gc/protect is not strictly necessary here, because we store it before any new allocation
               (,copier elements new-elements size)
               (set elements (put ,vector-type _bits obj new-elements))))
           (when (<= size idx)
             ;; record the largest ever written index + 1 (aka size) in the size slot
             (put ,vector-type size obj (new-<long> (+ 1 idx))))
           (set (,accessor elements idx) val)))

       (define-function ,append-name (obj val)
         (,setter-name obj (,length-name obj) val))

       (define-function ,insert-name (obj idx value)
         (let ((size (,length-name obj)))
           (,append-name obj 0) ; ensure that we have enough room
           (when (< idx size)
             (let* ((elements	(get ,vector-type _bits obj))
                    (src	(+ elements (* idx ,element-size-in-bytes))))
               (move-oops src
                          (+ src ,element-size-in-bytes)
                          (- size idx)))))
         (,setter-name obj idx value))

       (define-function ,zeroed-name (obj)
         (let ((size (,length-name obj)))
           (,setter-name obj size 0)
           (put ,vector-type size obj (new-<long> size)))
         obj))))

(define-vector-like array	()	oop-at		copy-oops	target/word-size-in-bytes)
(define-vector-like string	t	string-at	copy-bytes	1)