;;; -*- Gerbil -*-
;;; (C) vyzo at hackzen.org
;;; Gerbil stage0 -- Gambit-C host runtime
(##namespace (""))
;;(include "gx-gambc#.scm")

(declare 
  (block)
  (standard-bindings)
  (extended-bindings))

;;;
;;; Host Runtime
;;;  Implementation of a source compatible subset of gerbil.runtime
;;;  Sufficient to bootstrap the compiler
;;;

(define &current-module-libpath
  (make-parameter #f))
(define &current-module-registry
  (make-parameter #f))

(define (load-module modpath #!optional (reload? #f))
  (cond
   ((and (not reload?) (hash-get (&current-module-registry) modpath))
    => values)
   ((find-library-module modpath)
    => (lambda (path)
         (let ((lpath (load path)))
           (hash-put! (&current-module-registry) modpath lpath)
           lpath)))
   (else
    (error "Cannot load module; not found" modpath))))

(define (find-library-module modpath)
  (define (find-compiled-file npath)
    (let ((basepath (string-append npath ".o")))
      (let lp ((current #f) (n 1))
        (let ((next (string-append basepath (number->string n))))
          (if (file-exists? next)
            (lp next (fx1+ n))
            current)))))
  
  (define (find-source-file npath)
    (let ((spath (string-append npath ".scm")))
      (and (file-exists? spath) spath)))
          
  (let lp ((rest (&current-module-libpath)))
    (core-match rest
      ((dir . rest)
       (let ((npath (path-expand modpath dir)))
         (cond
          ((find-compiled-file npath) => path-normalize)
          ((find-source-file npath) => path-normalize)
          (else (lp rest)))))
      (else #f))))

(define (file-newer? file1 file2)
  (define (modification-time file)
    (time->seconds
     (file-info-last-modification-time
      (file-info file #t))))
  (> (modification-time file1)
     (modification-time file2)))

;; explicit namespace reference for loading compiled modules
(define (_gx#load-module modpath)
  (load-module modpath #f))
  
;;; MOP
;;
;; Gerbil rtd:
;;  {##struct-t id super fields name plist ctor slots methods}
;;  {##class-t  id super fields name plist ctor slots methods}
;;
;; Gambit structure rtd:
;;  (define-type type
;;    (id      unprintable: equality-test:)
;;    (name    unprintable: equality-skip:)
;;    (flags   unprintable: equality-skip:)
;;    (super   unprintable: equality-skip:)
;;    (fields  unprintable: equality-skip:))
;;
;; Gerbil rtd on gambit
;; ##structure ##type-type
;;  1  ##type-id
;;  2  ##type-name
;;  3  ##type-flags
;;  4  ##type-super
;;  5  ##type-fields
;;  6                       type-descriptor-super
;;  7                       type-descriptor-fields
;;  8                       type-descriptor-plist
;;  9                       type-descriptor-ctor
;; 10                       type-descriptor-slots
;; 11                       type-descriptor-methods
;;
;; struct-type
;;  ##type-super          =>  struct-type/#f
;;  type-descriptor-super => '##struct-type##
;; class-type
;;  ##type-super          => &class-type::t
;;  type-descriptor-super => [class-type ...]

(define &class-type::t
  (##structure ##type-type '##class-type## 'class-type 24 #f '#()))

(define (type-descriptor? klass)
  (and (##type? klass)
       (eq? (##vector-length klass) 12)))

(define (struct-type-descriptor? klass)
  (eq? (type-descriptor-super klass) '##struct-type##))

(define (class-type-descriptor? klass)
  (let ((super (##type-super klass)))
    (and super (eq? (##type-id super) '##class-type##))))

(define (struct-type? klass)
  (and (type-descriptor? klass)
       (struct-type-descriptor? klass)))

(define (class-type? klass)
  (and (type-descriptor? klass)
       (class-type-descriptor? klass)))

(define (make-type-descriptor type-id type-name type-super
                              rtd-super rtd-fields rtd-plist
                              rtd-ctor rtd-slots rtd-methods)
  (let* ((transparent? (assgetq transparent: rtd-plist))
         (field-names
          (cond
           ((assq fields: rtd-plist) => cdr)
           ((assq  slots: rtd-plist) => cdr)
           (else
            (make-list rtd-fields ':))))
         (field-info
          (let recur ((rest field-names))
            (core-match rest
              ((id . rest)
               (cons* id (if transparent? 0 1) #f (recur rest)))
              (else '())))))
    (##structure ##type-type 
                 type-id type-name 
                 (+ 24 (if transparent? 0 1))
                 type-super
                 (list->vector field-info)
                 rtd-super rtd-fields rtd-plist rtd-ctor 
                 rtd-slots rtd-methods)))

(define (make-struct-type-descriptor id name super fields plist ctor)
  (make-type-descriptor id name super '##struct-type## 
                        fields plist ctor #f #f))

(define (make-class-type-descriptor id name super fields plist ctor slots)
  (make-type-descriptor id name &class-type::t super 
                        fields plist ctor slots #f))

(define (type-descriptor-super klass)
  (##vector-ref klass 6))
(define (type-descriptor-fields klass)
  (##vector-ref klass 7))
(define (type-descriptor-plist klass)
  (##vector-ref klass 8))
(define (type-descriptor-ctor klass)
  (##vector-ref klass 9))
(define (type-descriptor-slots klass)
  (##vector-ref klass 10))
(define (type-descriptor-methods klass)
  (##vector-ref klass 11))
(define (type-descriptor-methods-set! klass ht)
  (##vector-set! klass 11 ht))

(define (make-struct-type id super fields name plist ctor)
  (when (and super (not (struct-type? super)))
    (error "Illegal super type; not a struct-type" super))
  (when (and super (assgetq final: (type-descriptor-plist super)))
    (error "Cannot extend final struct" super))

  (let* ((super-fields 
          (if super (type-descriptor-fields super) 0))
         (std-fields 
          (fx+ fields super-fields))
         (ctor 
          (or ctor (and super (type-descriptor-ctor super)))))
    (make-struct-type-descriptor id name super std-fields plist ctor)))

(define (make-struct-predicate klass)
  (let ((tid (##type-id klass)))
    (if (assgetq final: (type-descriptor-plist klass))
      (lambda (obj)
        (##structure-direct-instance-of? obj tid))
      (lambda (obj)
        (##structure-instance-of? obj tid)))))

(define (make-struct-field-accessor klass field)
  (let ((off (fx1+ (struct-field-offset klass field))))
    (lambda (obj)
      (##structure-ref obj off klass 'struct-field-ref))))

(define (make-struct-field-mutator klass field)
  (let ((off (fx1+ (struct-field-offset klass field))))
    (lambda (obj val)
      (##structure-set! obj val off klass 'struct-field-set!))))

(define (struct-field-offset klass field)
  (fx+ field 
       (cond
        ((##type-super klass) => type-descriptor-fields)
        (else 0))))

(define (struct-field-ref klass obj off)
  (##structure-ref obj (fx1+ off) klass 'struct-field-ref))

(define (struct-field-set! klass obj off val)
  (##structure-set! obj val (fx1+ off) klass 'struct-field-set!))

(define (make-class-type id super slots name plist ctor)
  (define (class-slots klass)
    (assgetq slots: (type-descriptor-plist klass)))
  
  (define (make-slots)
    (let ((slot-table (make-hash-table-eq)))
      (let lp ((rest super) (off 0) (slot-list '()))
        (core-match rest
          ((hd . rest)
           (merge-slots slot-table (class-slots hd) off slot-list 
                        (lambda (off slot-list)
                          (lp rest off slot-list))))
          (else
           (merge-slots slot-table slots off slot-list 
                        (lambda (off slot-list)
                          (values off slot-table (reverse slot-list)))))))))
  
  (define (merge-slots ht lst off r K)
    (let lp ((rest lst) (off off) (r r))
      (core-match rest
        ((slot . rest)
         (if (hash-get ht slot)
           (lp rest off r)
           (begin
             (hash-put! ht slot off)
             (hash-put! ht (symbol->keyword slot) off)
             (lp rest (fx1+ off) (cons slot r)))))
        (else
         (K off r)))))
  
  (define (find-super-ctor)
    (let lp ((rest super) (ctor #f))
      (core-match rest
        ((hd . rest)
         (cond
          ((type-descriptor-ctor hd)
           => (lambda (xctor)
                (if (or (not ctor) (eq? ctor xctor))
                  (lp rest xctor)
                  (error "Conflicting implicit constructors" ctor xctor))))
          (else (lp rest ctor))))
        (else ctor))))
  
  (cond
   ((find (lambda (klass) (not (class-type? klass))) super)
    => (lambda (klass)
         (error "Illegal super class; not a class-type" klass)))
   ((find (lambda (klass) 
             (assgetq final: (type-descriptor-plist klass))) 
           super)
    => (lambda (klass) 
         (error "Cannot extend final class" klass))))
  
  (let-values (((std-fields std-slots std-slot-list) (make-slots)))
    (let ((std-super  (class-linearize-mixins super))
          (std-plist  (cons (cons slots: std-slot-list) plist))
          (std-ctor   (or ctor (find-super-ctor))))
      (make-class-type-descriptor id name std-super 
                                 std-fields std-plist std-ctor std-slots))))

(define (class-linearize-mixins klass-lst)
  (define (class->list klass)
    (cons klass (type-descriptor-super klass)))
  
  (core-match klass-lst
    (() '())
    ((klass)
     (class->list klass))
    (else
     (&linearize-mixins 
      (map class->list klass-lst)))))

(define (&linearize-mixins lst)
  (define (K rest r)
    (core-match rest
      ((hd . rest)
       (linearize1 hd rest r))
      (else 
       (reverse r))))
  
  (define (linearize1 hd rest r)
    (core-match hd
      ((hd-first . hd-rest)
       (if (findq hd-first rest)
         (linearize2 rest (list hd) r)
         (K (cons hd-rest rest)
            (putq hd-first r))))
      (else 
       (K rest r))))
  
  (define (linearize2 rest pre r)
    (let lp ((rest rest) (pre pre))
      (core-match rest
        ((hd . rest)
         (core-match hd
           ((hd-first . hd-rest)
            (if (findq hd-first rest)
              (lp rest (cons hd pre))
              (K (foldl cons (cons hd-rest rest) pre)
                 (putq hd-first r))))
           (else
            (lp rest pre)))))))
  
  (define (putq hd lst)
    (if (memq hd lst) lst
        (cons hd lst)))
  
  (define (findq hd rest)
    (find (lambda (lst) (memq hd lst)) rest))
  
  (K lst '()))

(define (make-class-predicate klass)
  (if (assgetq final: (type-descriptor-plist klass))
    (lambda (obj)
      (direct-class-instance? klass obj))
    (lambda (obj)
      (class-instance? klass obj))))

(define (make-class-slot-accessor klass slot)
  (lambda (obj)
    (class-slot-ref klass obj slot)))

(define (make-class-slot-mutator klass slot)
  (lambda (obj val)
    (class-slot-set! klass obj slot val)))

(define (class-slot-offset klass slot)
  (hash-get (type-descriptor-slots klass) slot))

(define (class-slot-ref klass obj slot)
  (if (class-instance? klass obj)
    (let ((off (class-slot-offset (object-type obj) slot)))
      (##vector-ref obj (fx1+ off)))
    (raise-type-error 'class-slot-ref klass obj)))

(define (class-slot-set! klass obj slot val)
  (if (class-instance? klass obj)
    (let ((off (class-slot-offset (object-type obj) slot)))
      (##vector-set! obj (fx1+ off) val))
    (raise-type-error 'class-slot-set! klass obj)))

(define object? 
  ##structure?)
(define object-type 
  ##structure-type)

(define (struct-instance? klass obj)
  (##structure-instance-of? obj (##type-id klass)))

(define (direct-struct-instance? klass obj)
  (##structure-direct-instance-of? obj (##type-id klass)))

(define (class-instance? klass obj)
  (and (object? obj)
       (let ((klass-id (##type-id klass))
             (type (object-type obj)))
         (and (class-type? type)
              (or (eq? (##type-id type) klass-id)
                  (ormap (lambda (type) (eq? (##type-id type) klass-id))
                         (type-descriptor-super type)))))))

(define (direct-class-instance? klass obj)
  (##structure-direct-instance-of? obj (##type-id klass)))

(define (make-object klass k)
  (let ((obj (##make-vector (fx1+ k))))
    (##vector-set! obj 0 klass)
    (##subtype-set! obj (macro-subtype-structure))
    obj))

(define (make-struct-instance klass . args)
  (let ((fields (type-descriptor-fields klass)))
    (cond
     ((type-descriptor-ctor klass)
      => (lambda (kons-id) 
           (&constructor-init! klass kons-id (make-object klass fields) args)))
     ((fx= fields (length args))
      (apply ##structure klass args))
     (else
      (error "Arguments don't match object size" 
        klass fields args)))))

(define (make-direct-struct-instance klass . args)
  (let ((fields (type-descriptor-fields klass)))
    (if (fx<= (length args) fields)
      (&struct-instance-init! (make-object klass fields) args)
      (error "Too many arguments for struct" klass args))))

(define (make-class-instance klass . args)
  (let ((obj (make-object klass (type-descriptor-fields klass))))
    (cond
     ((type-descriptor-ctor klass)
      => (lambda (kons-id) 
           (&constructor-init! klass kons-id obj args)))
     (else 
      (&class-instance-init! klass obj args)))))

(define (make-direct-class-instance klass . args)
  (&class-instance-init! klass 
                         (make-object klass (type-descriptor-fields klass)) 
                         args))

(define (direct-struct-instance-init! obj . args)
  (if (fx< (length args) (##vector-length obj))
    (&struct-instance-init! obj args)
    (error "Too many arguments for struct" obj args)))

(define (&struct-instance-init! obj args)
  (let lp ((k 1) (rest args))
    (core-match rest
      ((hd . rest)
       (##vector-set! obj k hd)
       (lp (fx1+ k) rest))
      (else obj))))

(define (direct-class-instance-init! obj . args)
  (&class-instance-init! (object-type obj) obj args))

(define (&class-instance-init! klass obj args)
  (let lp ((rest args))
    (core-match rest
      ((key val . rest)
       (cond 
        ((class-slot-offset klass key)
         => (lambda (off) 
              (##vector-set! obj (fx1+ off) val)
              (lp rest)))
        (else
         (error "No slot for keyword initializer" klass key))))
      (else
       (if (null? rest) obj
           (error "Unexpected class initializer arguments" rest))))))

(define (direct-constructor-init! klass kons-id obj . args)
  (&constructor-init! klass kons-id obj args))

(define (&constructor-init! klass kons-id obj args)
  (cond
   ((direct-method-ref klass kons-id)
    => (lambda (kons) 
         (apply kons obj args) 
         obj))
   (else
    (error "Missing constructor" klass kons-id))))

(define (struct->list obj #!optional (start 0))
  (subvector->list obj start))

(define (class->list obj #!optional (init-list? #f))
  (error "XXX")
  )

(define (direct-field-ref obj off)
  (##vector-ref obj (fx1+ off)))
(define (direct-field-set! obj off val)
  (##vector-set! obj (fx1+ off) val))
(define (direct-slot-ref obj slot)
  (direct-field-ref obj (class-slot-offset (object-type obj))))
(define (direct-slot-set! obj slot val)
  (direct-field-set! obj (class-slot-offset (object-type obj)) val)) 

(define (slot-ref obj slot #!optional (E &slot-error))
  (&slot-e obj slot (lambda (off) (##vector-ref obj (fx1+ off))) E))

(define (slot-set! obj slot val #!optional (E &slot-error))
  (&slot-e obj slot (lambda (off) (##vector-set! obj (fx1+ off) val)) E))

(define (&slot-e obj slot K E)
  (if (object? obj)
    (let ((klass (object-type obj)))
      (cond 
       ((and (class-type? klass) (class-slot-offset klass slot))
        => K)
       (else (E obj slot))))
    (E obj slot)))

(define (&slot-error obj slot)
  (error "Cannot find slot" obj slot))

(define (call-method obj id . args)
  (cond
   ((method-ref obj id)
    => (lambda (method) (apply method obj args)))
   (else
    (error "Cannot find method" obj id))))

(define (method-ref obj id)
  (and (object? obj)
       (find-method (object-type obj) id)))

(define (bound-method-ref obj id)
  (cond
   ((method-ref obj id)
    => (lambda (method)
         (lambda args 
           (apply method obj args))))
   (else #f)))

(define (find-method klass id)
  (cond
   ((struct-type? klass)
    (struct-find-method klass id))
   ((class-type? klass)
    (class-find-method klass id))
   (else #f)))

(define (find-next-method klass id #!optional (obj #f))
  (cond
   ((struct-type? klass)
    (struct-find-next-method klass id))
   ((class-type? klass)
    (if obj
      (class-find-next-method* klass (object-type obj) id)
      (class-find-next-method klass id)))
   (else #f)))

(define (struct-find-method klass id)
  (struct-type-find
   (lambda (klass)
     (direct-method-ref klass id))
   klass))
 
(define (struct-find-next-method klass id)
  (struct-find-method (##type-super klass) id))

(define (class-find-method klass id)
  (class-type-find
   (lambda (klass)
     (direct-method-ref klass id))
   klass))

(define (class-find-next-method klass id)
  (class-type-find*
   (lambda (klass)
     (direct-method-ref klass id))
   (type-descriptor-super klass)))

(define (class-find-next-method* klass subklass id)
  (let ((tid (##type-id klass)))
    (if (eq? tid (##type-id subklass))
      (class-find-next-method klass id)
      (let lp ((rest (type-descriptor-super subklass)))
        (core-match rest
          ((hd . rest)
           (if (eq? tid (##type-id hd))
             (class-type-find*
              (lambda (klass)
                (direct-method-ref klass id))
              rest)
             (lp rest)))
          (else #f))))))

(define (struct-type-find proc klass)
  (let lp ((klass klass))
    (and klass
         (or (proc klass)
             (lp (##type-super klass))))))

(define (class-type-find proc klass)
  (or (proc klass)
      (class-type-find* proc (type-descriptor-super klass))))

(define (class-type-find* proc rest)
  (let lp ((rest rest))
    (core-match rest
      ((hd . rest)
       (or (proc hd)
           (lp rest)))
      (else #f))))

(define (direct-method-ref klass id)
  (cond
   ((type-descriptor-methods klass)
    => (lambda (ht) (hash-get ht id)))
   (else #f)))

(define (bind-method! klass id proc #!optional (rebind? #t))
  (let lp ((ht (type-descriptor-methods klass)))
    (if ht
      (cond
       ((hash-get ht id)
        => (lambda (prev)
             (unless rebind?
               (error "Method already bound" klass id))
             (hash-put! ht id proc)
             prev))
       (else
        (hash-put! ht id proc)
        #f))
      (let ((ht (make-hash-table-eq)))
        (type-descriptor-methods-set! klass ht)
        (lp ht)))))

;;; etc
;; use gambit type for this
(define (raise-type-error where type obj)
  (##raise-type-exception obj type where (list obj)))

(define _gx#atom (make-vector 0))

(define (true . _) 
  #t)
(define (true? obj)
  (eq? obj #t))

(define (false . _) 
  #f)

(define (void . _) 
  #!void)
(define (void? obj)
  (eq? obj #!void))

(define (identity obj)
  obj)

(define (dssl-object? obj)
  (and (memq obj '(#!key #!rest #!optional)) #t))
(define (dssl-key-object? obj)
  (eq? obj #!key))
(define (dssl-rest-object? obj)
  (eq? obj #!rest))
(define (dssl-optional-object? obj)
  (eq? obj #!optional))

(define (immediate? obj)
  (or (fixnum? obj)
      (char? obj)
      (boolean? obj)
      (null? obj)
      (void? obj)
      (eof-object? obj)
      (dssl-object? obj)))

(define (nonnegative-fixnum? obj)
  (and (fixnum? obj)
       (not (fxnegative? obj))))

(define (values-count obj)
  (if (##values? obj)
    (##vector-length obj)
    1))

(define (values-ref obj k)
  (if (##values? obj)
    (##vector-ref obj k)
    obj))

(define (values->list obj #!optional (start 0))
  (let ((lst (if (##values? obj)
               (##vector->list obj)
               (list obj))))
    (if (fxzero? start) lst
        (list-tail lst start))))

(define (subvector->list obj #!optional (start 0))
  (let ((lst (##vector->list obj)))
    (if (fxzero? start) lst
        (list-tail lst start))))

(define make-hash-table make-table)
(define (make-hash-table-eq . args)
  (apply make-table test: eq? args))
(define (make-hash-table-eqv . args)
  (apply make-table test: eqv? args))

(define list->hash-table list->table)
(define (list->hash-table-eq lst . args)
  (apply list->table lst test: eq? args))
(define (list->hash-table-eqv lst . args)
  (apply list->table lst test: eqv? args))

(define hash?
  table?)
(define hash-table?
  table?)

(define hash-length
  table-length)
(define hash-ref
  table-ref)
(define (hash-get ht k)
  (table-ref ht k #f))
(define (hash-put! ht k v)
  (table-set! ht k v))
(define (hash-update! ht k v update)
  (let ((cv (hash-ref ht k _gx#atom)))
    (if (eq? cv _gx#atom)
      (hash-put! ht k v)
      (hash-put! ht k (update v)))))
(define (hash-remove! ht k)
  (table-set! ht k))

(define hash->list
  table->list)

(define (hash->plist ht)
  (hash-fold cons* '() ht))

(define (plist->hash-table plst #!optional (ht (make-hash-table)))
  (let lp ((rest plst))
    (core-match rest
      ((k v . rest)
       (hash-put! ht k v)
       (lp rest))
      (() ht))))

(define (plist->hash-table-eq plst)
  (plist->hash-table plst (make-hash-table-eq)))
(define (plist->hash-table-eqv plst)
  (plist->hash-table plst (make-hash-table-eqv)))

(define (hash-key? ht k)
  (not (eq? _gx#atom (hash-ref ht k _gx#atom))))

(define hash-for-each
  table-for-each)

(define (hash-map fun ht)
  (hash-fold 
   (lambda (k v r) (cons (fun k v) r))
   '() ht))

(define (hash-fold fun iv ht)
  (let ((ret iv))
    (hash-for-each
     (lambda (k v) (set! ret (fun k v ret)))
     ht)
    ret))

(define hash-find
  table-search)

(define (hash-keys ht)
  (hash-map (lambda (k v) k) ht))

(define (hash-values ht)
  (hash-map (lambda (k v) v) ht))

(define (hash-copy hd . rest)
  (let ((hd (table-copy hd)))
    (if (null? rest) hd
        (apply hash-copy! hd rest))))

(define (hash-copy! hd . rest)
  (for-each (lambda (r) (table-merge! hd r)) rest)
  hd)

(define (make-list k #!optional (val #f))
  (let lp ((n 0) (r '()))
    (if (fx< n k)
      (lp (fx1+ n) (cons val r))
      r)))

(define (cons* x y . rest)
  (if (null? rest)
    (cons x y)
    (cons x (apply cons* y rest))))

(define (foldl f iv lst . rest)
  (define (fold1 iv rest)
    (core-match rest
      ((hd . rest)
       (fold1 (f hd iv) rest))
      (else iv)))
  
  (define (fold* iv rest)
    (if (andmap pair? rest)
      (fold* (apply f (foldr (lambda (xs r) (cons (car xs) r))
                             (list iv) rest))
             (map cdr rest))
      iv))
  
  (if (null? rest)
    (fold1 iv lst)
    (fold* iv (cons lst rest))))

(define (foldr f iv lst . rest)
  (define (fold1 iv rest)
    (core-match rest
      ((hd . rest)
       (f hd (fold1 iv rest)))
      (else iv)))
  
  (define (fold* iv rest)
    (if (andmap pair? rest)
      (apply f 
        (foldr (lambda (xs r) (cons (car xs) r))
               (list (fold* iv (map cdr rest)))
               rest))
      iv))
  
  (if (null? rest)
    (fold1 iv lst)
    (fold* iv (cons lst rest))))

(define (andmap f lst . rest)
  (define (fold1 rest)
    (core-match rest
      ((hd . rest)
       (and (f hd) 
            (fold1 rest)))
      (else #t)))

  (define (fold* rest)
    (if (andmap pair? rest)
      (and (apply f (map car rest))
           (fold* (map cdr rest)))
      #t))
  
  (if (null? rest)
    (fold1 lst)
    (fold* (cons lst rest))))

(define (ormap f lst . rest)
  (define (fold1 rest)
    (core-match rest
      ((hd . rest)
       (or (f hd) 
           (fold1 rest)))
      (else #f)))
  
  (define (fold* rest)
    (if (andmap pair? rest)
      (or (apply f (map car rest))
           (fold* (map cdr rest)))
      #f))
  
  (if (null? rest)
    (fold1 lst)
    (fold* (cons lst rest))))

(define (filter f lst)
  (let recur ((rest lst))
    (core-match rest
      ((hd . rest)
       (if (f hd)
         (cons hd (recur rest))
         (recur rest)))
      (else '()))))

(define (filter-map f lst . rest)
  (define (fold1 rest)
    (core-match rest
      ((hd . rest)
       (cond
        ((f hd) => (lambda (r) (cons r (fold1 rest))))
        (else (fold1 rest))))
      (else '())))
  
  (define (fold* rest)
    (if (andmap pair? rest)
      (cond
       ((apply f (map car rest))
        => (lambda (r) (cons r (fold* (map cdr rest)))))
       (else
        (fold* (map cdr rest))))
      '()))
  
  (if (null? rest)
    (fold1 lst)
    (fold* (cons lst rest))))

(define (iota count #!optional (start 0) (step 1))
  (let lp ((k 0) (x start) (r '()))
    (if (< k count)
      (lp (fx1+ k) (+ x step) (cons x r))
      (reverse r))))

(define (last-pair lst)
  (core-match lst
    ((_ . rest)
     (if (pair? rest)
       (last-pair rest)
       lst))))

(define (last lst)
  (car (last-pair lst)))

(define (assgetq key lst #!optional (E false))
  (cond
   ((and (pair? lst) (assq key lst)) => cdr)
   (else (E key))))

(define (pgetq key lst #!optional (E false))
  (pget key lst E memq))

(define (pgetv key lst #!optional (E false))
  (pget key lst E memv))

(define (pget key lst #!optional (E false) (getf member))
  (cond
   ((getf key lst) => cadr)
   (else (E key))))

(define (find pred lst)
  (cond
   ((memf pred lst) => car)
   (else #f)))

(define (memf proc lst)
  (let lp ((rest lst))
    (core-match rest
      ((hd . tl)
       (if (proc hd) rest (lp tl)))
      (else #f))))

(define (remove el lst #!optional (p? equal?))
  (let lp ((rest lst) (r '()))
    (core-match rest
      ((hd . rest)
       (if (p? el hd)
         (foldl cons rest r)
         (lp rest (cons hd r))))
      (else lst))))

(define (remv el lst)
  (remove el lst eqv?))
(define (remq el lst)
  (remove el lst eq?))

(define (remf proc lst)
  (let lp ((rest lst) (r '()))
    (core-match rest
      ((hd . rest)
       (if (proc hd)
         (foldl cons rest r)
         (lp rest (cons hd r))))
      (else lst))))

(define (1+ x)
  (+ x 1))
(define (1- x)
  (- x 1))
(define (fx1+ x)
  (fx+ x 1))
(define (fx1- x)
  (fx- x 1))
(define fxshift
  fxarithmetic-shift)

(define (interned-symbol? x)
  (and (symbol? x)
       (not (uninterned-symbol? x))))

(define (make-symbol . args)
  (string->symbol
   (apply string-append
     (map (lambda (x)
            (cond
             ((string? x) x)
             ((symbol? x) (symbol->string x))
             (else (error "Not a symbol or string" x))))
          args))))

(define (interned-keyword? x)
  (and (keyword? x)
       (not (uninterned-keyword? x))))

(define (symbol->keyword sym)
  ((if (uninterned-symbol? sym)
     string->uninterned-keyword
     string->keyword)
   (symbol->string sym)))

(define (keyword->symbol kw)
  ((if (uninterned-keyword? kw)
     string->uninterned-symbol
     string->symbol)
   (keyword->string kw)))

(define (bytes->string bstr)
  (let* ((in (open-input-u8vector `(char-encoding: UTF-8 init: ,bstr)))
         (len (u8vector-length bstr))
         (out (make-string len))
         (n (read-substring out 0 len in)))
    (string-shrink! out n)
    out))

(define (string->bytes str)
  (substring->bytes str 0 (string-length str)))

(define (substring->bytes str start end)
  (let ((out (open-output-u8vector '(char-encoding: UTF-8))))
    (write-substring str start end out)
    (get-output-u8vector out)))

(define (string-empty? str)
  (##fxzero? (string-length str)))

(define (string-index str char #!optional (start 0))
  (let ((len (string-length str)))
    (let lp ((k start))
      (and (fx< k len)
           (if (eq? char (##string-ref str k)) k
               (lp (fx1+ k)))))))

(define (string-rindex str char #!optional (start #f))
  (let* ((len (string-length str))
         (start (or start (fx1- len))))
    (let lp ((k start))
      (and (fx>= k 0)
           (if (eq? char (##string-ref str k)) k
               (lp (fx1- k)))))))

(define (string-split str char)
  (let ((len (string-length str)))
    (let lp ((start 0) (r '()))
      (cond
       ((string-index str char start)
        => (lambda (end)
             (lp (fx1+ end) (cons (substring str start end) r))))
       ((fx< start len)
        (foldl cons (list (substring str start len)) r))
       (else
        (reverse r))))))

(define (string-join strs join)
  (let ((join (if (char? join)
                (string join)
                join)))
    (let recur ((rest strs))
      (core-match rest
        ((hd) hd)
        ((hd . rest)
         (string-append hd join (recur rest)))
        (else "")))))

(define (vector-map f vec . rest)
  (define (fold1 vec)
    (let* ((len (vector-length vec))
           (r (make-vector len)))
      (do ((k 0 (fx1+ k)))
          ((fx= k len) r)
        (##vector-set! r k (f (##vector-ref vec k))))))
  
  (define (fold* vecs)
    (let* ((len (apply min (map vector-length vecs)))
           (r (make-vector len)))
      (do ((k 0 (fx1+ k)))
          ((fx= k len) r)
        (##vector-set! r k 
                       (apply f 
                         (map (lambda (vec) (##vector-ref vec k)) 
                              vecs))))))
  
  (if (null? rest)
    (fold1 vec)
    (fold* (cons vec rest))))

(define (displayln . args)
  (let lp ((rest args))
    (core-match rest
      ((hd . rest)
       (display hd)
       (lp rest))
      (else
       (newline)))))

(define (display* . args)
  (for-each display args))

;; control
(define make-promise
  ##make-promise)

(define (call-with-parameters thunk . rest)
  (core-match rest
    ((param val . rest)
     (##parameterize param val
                     (if (null? rest) thunk
                         (lambda () (apply call-with-parameters thunk rest)))))
    (() (thunk))))

(define (call-with-escape K)
  (call/cc K))

(define with-catch
  with-exception-catcher)

(define (with-unwind-protect K fini)
  (let ((once #f))
    (dynamic-wind
      (lambda ()
        (declare (not interrupts-enabled))
        (when once
          (error "Cannot reenter unwind protected block"))
        (set! once #t))
      K fini)))

;; gerbil errors
(define error::t
  (make-struct-type 'gerbil#error::t #f 3 'error '() #f))
(define type-error::t
  (make-struct-type 'gerbil#type-error::t error::t 1 'type-error '() #f))

;; some minimal integration with gambit exceptions
(define (error? obj)
  (or (struct-instance? error::t obj)
      (##structure-instance-of? obj (##type-id (macro-type-exception)))))

(define (type-error? obj)
  (or (struct-instance? type-error::t obj)
      (##structure-instance-of? obj (##type-id (macro-type-type-exception)))))

(define (error-trace obj)
  (and (struct-instance? error::t obj)
       (##vector-ref obj 1)))

(define (error-message obj)
  (cond
   ((struct-instance? error::t obj)
    (##vector-ref obj 2))
   ((error-exception? obj)
    (error-exception-message obj))
   (else #f)))

(define (error-irritants obj)
  (cond
   ((struct-instance? error::t obj)
    (##vector-ref obj 3))
   ((error-exception? obj)
    (error-exception-parameters obj))
   (else '())))

;;; assorted
(define (create-directory* dir #!optional (perms #o755))
  (define (create1 path)
    (cond 
     ((file-exists? path)
      (unless (eq? (file-type path) 'directory)
        (error "Path component is not a directory" path)))
     (perms
      (create-directory (list path: path permissions: perms)))
     (else
      (create-directory path))))
  
  (let lp ((start 0))
    (cond
     ((string-index dir #\/ start) 
      => (lambda (x)
           (when (fx> x 0)
             (create1 (substring dir 0 x)))
           (lp (fx1+ x))))
     (else
      (create1 dir)
      (path-normalize dir)))))

;; kwt: #f or a vector as a perfect hash-table for expected keywords
(define (keyword-dispatch kwt K . all-args)
  (when kwt
    (unless (vector? kwt)
      (##raise-type-exception 1 'vector 'keyword-dispatch
                              (cons* kwt K all-args))))
  (unless (procedure? K)
    (##raise-type-exception 2 'procedure 'keyword-dispatch 
                            (cons* kwt K all-args)))
  (let ((keys 
         (if kwt
           (make-hash-table-eq hash: keyword-hash size: (##vector-length kwt))
           (make-hash-table-eq hash: keyword-hash))))
    (let lp ((rest all-args) (args #f) (tail #f))
      (core-match rest
        ((hd . hd-rest)
         (cond
          ((keyword? hd)
           (core-match hd-rest
             ((val . rest)
              (when kwt
                (let ((pos (fxmodulo (keyword-hash hd) (##vector-length kwt))))
                  (unless (eq? hd (##vector-ref kwt pos))
                    (error "Unexpected keyword argument" K hd))))
              (when (hash-key? keys hd)
                (error "Duplicate keyword argument" K hd))
              (hash-put! keys hd val)
              (lp rest args tail))))
          ((eq? hd #!key)               ; keyword escape
           (core-match hd-rest
             ((val . rest)
              (if args
                (begin
                  (##set-cdr! tail hd-rest)
                  (lp rest args hd-rest))
                (lp rest hd-rest hd-rest)))))
          ((eq? hd #!rest)              ; end keyword processing
           (if args
             (begin
               (##set-cdr! tail hd-rest)
               (##apply K (cons keys args)))
             (##apply K (cons keys hd-rest))))
          (else                         ; plain argument
           (if args
             (begin
               (##set-cdr! tail rest)
               (lp hd-rest args rest))
             (lp hd-rest rest rest)))))
        (else
         (if args
           (begin
             (##set-cdr! tail '())
             (##apply K (cons keys args)))
           (K keys)))))))