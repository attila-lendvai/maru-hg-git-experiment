;;; -*- mode: lisp; coding: us-ascii -*-

(set-working-directory *slave-directory*)

(define *host-module* (current-module))

(let ((slave-module (module "slave")))
  (define *slave-module* slave-module)
  (define switch-to-slave-module
      (lambda ()
        ;;(warn "--- switching to the slave module\n")
        (set (current-module) *slave-module*)))
  (switch-to-slave-module)
  ;; in the slave, set the global variable called 'host' to hold the host-module
  ;; NOTE this toplevel form is encoded into the host. the previous
  ;; switch-to-slave-module happens at runtime, it has no effect on the
  ;; encode phase. therefore the use of eval-in-module below.
  (eval-in-module *slave-module* `(define *host-module* ,*host-module*)))

;; NOTE: we are in the slave module now, and the following forms will be read/interned into the slave.
;; NOTE: the slave module doesn't have boot.l loaded at this point, we only have the primitives.

;; The variable bootstrapping? denotes that the process is underway in which a host loads a slave into an isolated module,
;; and then compiles the definitions to the target (does the level-shift).
(define bootstrapping? true)

;; The variable evolving? denotes that the host running the bootstrapping process is
;; the previous stage, i.e. an earlier version of us. It will be set in host-extras.l
;; if it gets loaded.
(define evolving? ())

(define switch-to-host-module
    (lambda ()
      ;;(warn "--- switching to the host  module\n")
      (set-current-module *host-module*)))

(define eval-in-host (lambda (form)
                       (eval-in-module *host-module* form)))

(switch-to-host-module)

;; *slave-env* will be the direct parent of *target-env* (i.e. lookup is delegated to it).
;; you can think of *slave-env* as the syntax-module of the target: all macros,
;; constants, and any meta-level stuff are evaluated in that environment.
;; *target-env* will be set up later in emit-early.l.
;;(define *slave-env* (eval-in-module *slave-module* '*globals*))
(define *slave-env* (let ((globals (eval-in-module *slave-module* '(oop-at (current-module) 0))))
                      (when (is <variable> globals)
                        (set globals (<variable>-value globals)))
                      globals))

(define-function eval-in-slave (form)
  ;; NOTE don't optimize this to (eval form *slave-env*) when (=
  ;; *module* *slave-module*) because the ENCODE of DEFINE defines
  ;; into the *globals* of the current module, not the passed env.
  (let ((wrapped `(let ((prev-globals *globals*)
                        result)
                    (set *globals* ,*slave-env*)
                    (set result (,eval ',form)) ; let's capture the EVAL fixed here, because otherwise it would be encoded to EVAL from the target env
                    (set *globals* prev-globals)
                    result)))
    (eval-in-module *slave-module*
      wrapped)))

(define-function eval-in-target (form)
  (assert (not (= *slave-env* (eval-in-module *slave-module* '*globals*))) "eval-in-target called too early in the bootstrap process?!")
  (eval-in-module *slave-module* form))

(define-form slave-value (form)
  `(eval-in-slave ',form))