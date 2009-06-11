(define externs)

(define assemble
  (lambda (name expr)
    (let ((out (open-output-file (format "~a.ll" name) 'replace)))
      (assemble:program out expr)
      (close-output-port out))))

(define assemble:program
  (lambda (out prog)
    (cond
     ((and (list? prog) (equal? (car prog) 'program))
      (set! externs (find-externs prog))
      (for-each (assemble:function out externs) (cadr prog))
      (for-each (lambda (extfn)
                  (fprintf out "declare ~a @~a(...)\n" llvm:int extfn))
                externs))
     (else
      (error 'assemble:program
             "Invalid program: ~a" prog)))))

(define assemble:app
  (lambda (out)
    (trace-lambda a:app (expr)
      (let* ((arg-regs (map (assemble:arg out) (cdr expr)))
             (res (next-counter "tmp")))
        
        (if (prim? (car expr))
            ((assemble:app:primop out) res (car expr) arg-regs)
            ((assemble:app:call-c out) res (car expr) arg-regs)))
        )))

(define assemble:app:call-c
  (lambda (out)
    (lambda (res fn args)
      (fprintf out "~a = call ~a~a @~a"
               res
               llvm:int
               (if (member fn externs)
                   " (...)*"
                   "")
               fn)
      (assemble:function:arglist out args)
      (fprintf out "\n")
      res
      )))

(define assemble:app:primop
  (lambda (out)
    (lambda (res op args)
      (if (binary-prim? op)
          (let ((arg2
                 (case op
                   ((fx*) (let ((reg2 (next-counter "shr")))
                            (fprintf out "~a = ashr ~a ~a, 2\n"
                                     reg2 llvm:int (cadr args))
                            reg2))
                   (else (cadr args))))
                (target (case op
                          ((fx/) (next-counter "tmp"))
                          (else res))))
            (fprintf out "~a = " target)
            (fprintf out
                     "~a ~a ~a, ~a\n"
                     (case op
                       ((fx+) 'add)
                       ((fx-) 'sub)
                       ((fx*) 'mul)
                       ((fx/)  'sdiv)
                       ((remainder) 'srem)
                       (else (error 'assemble:app:primop
                                    "Support for operator not added: ~a" op)))
                     
                       llvm:int (car args) arg2)
            (case op
              ((fx/)
               (fprintf out "~a = shl ~a ~a, 2\n"
                        res llvm:int target)))
            res)
          (else
           (error 'assemble:app:primop
                  "Non-binary primops not supported yet: ~a" op))))))

(define assemble:arg
  (lambda (out)
    (lambda (expr)
      (cond
       ((immediate? expr) expr)
       (else ((assemble:expr out) expr))))))

(define assemble:expr
  (lambda (out)
    (trace-lambda a:expr (expr)
      (cond
       ((immediate? expr)
        (let* ((t (next-counter "tmp"))
               (res (next-counter "tmp")))
          (fprintf out "~a = alloca ~a\n" t llvm:int)
          (fprintf out "store ~a ~a, ~a* ~a\n" llvm:int expr llvm:int t)
          (fprintf out "~a = load ~a* ~a\n" res llvm:int t)
          res))
       ((symbol? expr) expr)
       ((if? expr)
        (assemble:if out expr))
       ((list? expr)
        ((assemble:app out) expr))
       (else
        (error 'assemble:expr
               "Unknown expression: ~a" expr))))))

(define assemble:if
  (lambda (out expr)
    (let ((test (cadr expr))
          (conseq (caddr expr))
          (alt    (cadddr expr)))
      (unless (equal? (car test) 'eq?)
        (error 'assemble:if
               "Test not simplified to eq? form: ~s" test))
      (let ((res (next-counter "res"))
            (cmp (next-counter "cmp"))
            (label-then (next-counter "if.then"))
            (label-else (next-counter "if.else"))
            (label-done (next-counter "if.done")))
        (fprintf out "~a = alloca ~a\n"
                 res
                 llvm:int)
        (let ((v1 ((assemble:expr out) (cadr test)))
              (v2 ((assemble:expr out) (caddr test))))
          (fprintf out "~a = icmp eq ~a ~a, ~a\n"
                   cmp
                   llvm:int
                   v1
                   v2)
          (fprintf out "br i1 ~a, label ~a, label ~a\n"
                   cmp
                   label-then
                   label-else)
          (assemble:if:block out res label-then conseq label-done)
          (assemble:if:block out res label-else alt label-done)
          (print-label out label-done)
          (let ((result (next-counter "if.result")))
            (fprintf out "~a = load ~a* ~a\n"
                     result llvm:int res)
            result))))))

(define assemble:if:block
  (lambda (out res label expr jump-label)
    (print-label out label)
    (let ((val
           ((assemble:expr out) expr)))
      (fprintf out "store ~a ~a, ~a* ~a\n"
               llvm:int
               val
               llvm:int
               res)
      (fprintf out "br label ~a\n" jump-label))))
    

(define assemble:function
  (lambda (out externs)
    (trace-lambda a:fn (fn)
      (let ((name (car fn))
            (args (cadr fn))
            (bexprs (cddr fn))
            )
        (reset-counter)
        (fprintf out "define ~a @~a" llvm:int name)
        (assemble:function:arglist out args)
        (fprintf out "{\n")
        ;;(for-each (assemble:expr out) bexprs)
        (fprintf out "entry:\n")
        (let ((res ((assemble:expr out) (car bexprs))))
          (fprintf out "ret ~a ~a\n" llvm:int res))
        (fprintf out "}\n\n")))))

(define assemble:function:arglist
  (lambda (out args)
    (fprintf out "(")
    (let loop ((args args))
      (unless (null? args)
        (fprintf out "~a ~a" llvm:int (car args))
        (unless (null? (cdr args))
          (fprintf out ", "))
        (loop (cdr args))))
    (fprintf out ")")))
