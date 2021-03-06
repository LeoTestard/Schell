#lang racket

(require racket/string)
(require (prefix-in schell: "variables.rkt"))
(require (prefix-in schell: "environment.rkt"))
(require (prefix-in schell: "command.rkt"))
(require (prefix-in schell: "builtins.rkt"))
(require (prefix-in schell: "functions.rkt"))
(require (prefix-in schell: "begin.rkt"))
(require (prefix-in schell: "conditionals.rkt"))
(require (prefix-in schell: "expander.rkt"))
(provide $eval)

(define-struct exn:command-not-found (command))
(define-namespace-anchor anchor)

; whereis : string? -> string?
; return the full file path of the given command. If cmd is not a 
; relative nor absolute file path, search it in the PATH
(define (whereis command)
  (if (or (eq? (string-ref command 0) #\.) (eq? (string-ref command 0) #\/))
      ; relative or absolute path
      command   
      ; search in PATH
      (let ((PATH (string-split (getenv "PATH") ":")))
        (letrec ((locate-path
                   (lambda (command path)
                     (if (null? path)
                       (raise (make-exn:command-not-found command))
                       (let ((test (build-path (car path) command)))
                         (if (file-exists? test) test
                           (locate-path command (cdr path))))))))
          (path->string (locate-path command PATH))))))

; eval-args : list? -> list?
; evaluates a list of arguments and put them in a list
(define (eval-args args env)
  (if (null? args) null
    (let ((carargs ($eval (car args) env)))
      (cons carargs (eval-args (cdr args) env)))))

; bind-env : list? list? -> list?
; bind the values contained in the second list to the names contained in
; the first list and return them in an environment (a list of pairs of string
; and value. Return #f if the size of lists doesn't match
(define (bind-env names vars)
  (cond
    ((null? names) 
     (if (null? vars) null #f))
    ((null? vars) 
     (if (null? names) null #f))
    (else
      (cons (mcons (symbol->string (car names)) (car vars))
            (bind-env (cdr names) (cdr vars))))))

; function-apply : function? list -> any
; arguments are ignored for now
(define (function-apply func args)
  ($eval (schell:function-expr func)
         (mcons (bind-env (schell:function-args func) args)
                (schell:function-env func))))

; run-command : command? list? -> number? list?
; executes an external or internal command and return its exit code
; first search through builtin commands, then external programs
; some builtin functions can modify the environnement so return the
; modified environnement
(define (run-command cmd env)
  (printf "Running ~a\n" cmd)
  (let ((command ($eval (schell:command cmd) env))
        (args (eval-args (schell:arguments cmd) env))
        (namespace (namespace-anchor->namespace anchor)))
    (printf "Command: ~a\n" command)
    (if (schell:function? command)
      (function-apply command args)
      (let ((builtin (schell:envsearch schell:builtin-commands command)))
        (if (false? builtin)
          (let-values
            (((proc out in err)
              (let ((stdin (current-input-port))
                    (stdout (current-output-port))
                    (stderr (current-error-port))
                    (command (whereis command)))
                (parameterize ((current-directory (current-directory)))
                  (eval
                    (append (list subprocess stdout stdin stderr command) args)
                    namespace)))))
              (subprocess-wait proc)
              (subprocess-status proc))
          (eval (append
                  (list builtin env)
                  (map (lambda (arg) (list 'quote arg)) args))
                namespace))))))

; eval : SchellExpr? -> (or/c string? function? list?)
; evaluates a Schell expression in the given environment
; returns a string containing the result of the expression and the modified
; environment
;
; <SchellExpr> ::= <atom>
;               |  $ <variable>
;               |  ( quote <SchellExpr>)
;               |  ( if <SchellExpr> <SchellExpr> <ShellExpr> )
;               |  ( set! <variable> <SchellExpr> )
;               |  ( begin <SchellExpr>* )
;               |  ( lambda ( <variable>* ) <SchellExpr> )
;               |  ( <SchellExpr>+ )
;
(define ($eval expr env)
  (printf "eval ~a in ~a\n" expr env)
  (let ((expr (schell:expand expr)))
    (cond
      ((schell:quote? expr) (cadr expr))

       ((schell:variable? expr)
       (schell:variable-value
         (schell:variable-name expr)
         env schell:builtin-variables))

     ((schell:if-expr? expr)
       (if (string=? ($eval (cadr expr) env) schell:true)
         ($eval (caddr expr) env)
         ($eval (cadddr expr) env)))

      ((schell:begin? expr)
       (let ((exprs (cdr expr)))
         (cond
           ((null? exprs) (void))
           ((null? (cdr exprs)) ($eval (car exprs) env))
           (else
             (begin
               ($eval (car exprs) env)
               ($eval (cons 'begin (cdr exprs)) env))))))

      ((schell:lambda? expr)
       (schell:make-function
         env (schell:lambda-args expr)
         (schell:lambda-expr expr)))

      ((schell:command? expr)
       (run-command expr env))

      ((boolean? expr)
       (if expr schell:true schell:false))

      ((number? expr)
       (number->string expr))

      ((schell:text? expr)
       (symbol->string expr))

      ((string? expr) expr))))
