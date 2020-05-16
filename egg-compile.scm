;;;; egg-info processing and compilation
;
; Copyright (c) 2017-2020, The CHICKEN Team
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
; conditions are met:
;
;   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
;     disclaimer.
;   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
;     disclaimer in the documentation and/or other materials provided with the distribution.
;   Neither the name of the author nor the names of its contributors may be used to endorse or promote
;     products derived from this software without specific prior written permission.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
; AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
; CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
; OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
; POSSIBILITY OF SUCH DAMAGE.


(define default-extension-options '())
(define default-program-options '())
(define default-static-program-link-options '())
(define default-dynamic-program-link-options '())
(define default-static-extension-link-options '())
(define default-dynamic-extension-link-options '())
(define default-static-compilation-options '("-O2" "-d1"))
(define default-dynamic-compilation-options '("-O2" "-d1"))
(define default-import-library-compilation-options '("-O2" "-d0"))

(define default-program-linkage
  (if staticbuild '(static) '(dynamic)))

(define default-extension-linkage
  (if staticbuild '(static) '(static dynamic)))

(define +unix-executable-extension+ "")
(define +windows-executable-extension+ ".exe")
(define +unix-object-extension+ ".o")
(define +unix-archive-extension+ ".a")
(define +windows-object-extension+ ".obj")
(define +windows-archive-extension+ ".a")
(define +link-file-extension+ ".link")

(define keep-generated-files #f)


;;; some utilities

(define override-prefix
  (let ((prefix (get-environment-variable "CHICKEN_INSTALL_PREFIX")))
    (lambda (dir default)
      (if prefix
          (string-append prefix dir)
          default))))

(define (object-extension platform)
  (case platform
    ((unix) +unix-object-extension+)
    ((windows) +windows-object-extension+)))

(define (archive-extension platform)
  (case platform
    ((unix) +unix-archive-extension+)
    ((windows) +windows-archive-extension+)))

(define (executable-extension platform)
  (case platform
     ((unix) +unix-executable-extension+)
     ((windows) +windows-executable-extension+)))

(define (copy-directory-command platform)
  (case platform
    ((unix) "cp -r")
    ((windows) "xcopy /y /i /e")))

(define (mkdir-command platform)
  (case platform
    ((unix) "mkdir -p")
    ((windows) "mkdir")))

(define (install-executable-command platform)
  (string-append default-install-program " "
		 default-install-program-executable-flags))

(define (install-file-command platform)
  (string-append default-install-program " "
		 default-install-program-data-flags))

(define (remove-file-command platform)
  (case platform
    ((unix) "rm -f")
    ((windows) "del /f /q")))

(define (cd-command platform)
  (case platform
    ((unix) "cd")
    ((windows) "cd /d")))

(define (uses-compiled-import-library? mode)
  (if (eq? mode 'target)
      #f
      (not (and (eq? mode 'host) staticbuild))))


;;; topological sort with cycle check

(define (sort-dependencies dag eq)
  (condition-case (topological-sort dag eq)
    ((exn runtime cycle)
     (error "cyclic dependencies" dag))))


;;; collect import libraries for all modules

(define (import-libraries mods dest rtarget mode)
  (define (implib name)
    (conc dest "/" name ".import."
          (if (uses-compiled-import-library? mode)
              "so"
              "scm")))
  (if mods
      (map implib mods)
      (list (implib rtarget))))


;;; check condition in conditional clause

(define (check-condition tst mode link)
  (define (fail x)
    (error "invalid conditional expression in `cond-expand' clause"
           x))
  (let walk ((x tst))
    (cond ((and (list? x) (pair? x))
           (cond ((and (eq? (car x) 'not) (= 2 (length x)))
                  (not (walk (cadr x))))
                 ((eq? 'and (car x)) (every walk (cdr x)))
                 ((eq? 'or (car x)) (any walk (cdr x)))
                 (else (fail x))))
          ((memq x '(dynamic static)) (memq x link))
          ((memq x '(target host)) (memq x mode))
          ((symbol? x) (feature? x))
          (else (fail x)))))


;;; compile an egg-information tree into abstract build/install operations

(define (compile-egg-info eggfile info version platform mode)
  (let ((exts '())
        (prgs '())
        (objs '())
        (data '())
        (genfiles '())
        (cinc '())
        (scminc '())
        (target #f)
        (src #f)
        (files '())
        (ifiles '())
        (cbuild #f)
        (oname #f)
        (link '())
        (dest #f)
        (sdeps '())
        (cdeps '())
        (lopts '())
        (opts '())
        (mods #f)
        (lobjs '())
        (tfile #f)
        (ptfile #f)
        (ifile #f)
        (eggfile (locate-egg-file eggfile))
        (objext (object-extension platform))
        (arcext (archive-extension platform))
        (exeext (executable-extension platform)))
    (define (check-target t lst)
      (when (member t lst)
        (error "target multiply defined" t))
      t)
    (define (addfiles . filess)
      (set! ifiles (concatenate (cons ifiles filess)))
      files)
    (define (compile-component info)
      (case (car info)
        ((extension)
          (fluid-let ((target (check-target (cadr info) exts))
                      (cdeps '())
                      (sdeps '())
                      (src #f)
                      (cbuild #f)
                      (link (if (eq? mode 'target)
                                '(static)
                                (if (null? link) default-extension-linkage link)))
                      (tfile #f)
                      (ptfile #f)
                      (ifile #f)
                      (lopts lopts)
                      (lobjs '())
                      (oname #f)
                      (mods #f)
                      (opts opts))
            (for-each compile-extension/program (cddr info))
            (let ((dest (destination-repository mode #t))
                  ;; Respect install-name if specified
                  (rtarget (or oname target)))
              (when (eq? #t tfile) (set! tfile rtarget))
              (when (eq? #t ifile) (set! ifile rtarget))
              (addfiles 
                (if (memq 'static link)
                    (list (conc dest "/" rtarget
                                (if (null? lobjs)
                                    objext
                                    arcext))
                          (conc dest "/" rtarget +link-file-extension+))
                    '())
                (if (memq 'dynamic link) (list (conc dest "/" rtarget ".so")) '())
                (if tfile 
                    (list (conc dest "/" tfile ".types"))
                    '())
                (if ifile 
                    (list (conc dest "/" ifile ".inline"))
                    '())
                (import-libraries mods dest rtarget mode))
              (set! exts
                (cons (list target
                            dependencies: cdeps
                            source: src options: opts
                            link-options: lopts linkage: link custom: cbuild
                            mode: mode types-file: tfile inline-file: ifile
                            predefined-types: ptfile eggfile: eggfile
                            modules: (or mods (list rtarget))
                            source-dependencies: sdeps
                            link-objects: lobjs
                            output-file: rtarget)
                    exts)))))
        ((c-object)
          (fluid-let ((target (check-target (cadr info) exts))
                      (cdeps '())
                      (sdeps '())
                      (src #f)
                      (cbuild #f)
                      (link (if (eq? mode 'target)
                                '(static)
                                (if (null? link) default-extension-linkage link)))
                      (oname #f)
                      (mods #f)
                      (opts opts))
            (for-each compile-extension/program (cddr info))
            (let ((dest (destination-repository mode #t))
                  ;; Respect install-name if specified
                  (rtarget (or oname target)))
              (set! objs
                (cons (list target dependencies: cdeps source: src
                            options: opts
                            linkage: link custom: cbuild
                            mode: mode
                            eggfile: eggfile
                            source-dependencies: sdeps
                            output-file: rtarget)
                      objs)))))
        ((data)
          (fluid-let ((target (check-target (cadr info) data))
                      (dest #f)
                      (files '()))
            (for-each compile-data/include (cddr info))
            (let* ((dest (or dest 
                             (if (eq? mode 'target)
                                 default-sharedir    ; XXX wrong!
                                 (override-prefix "/share" host-sharedir))))
                   (dest (normalize-pathname (conc dest "/"))))
              (addfiles (map (cut conc dest <>) files)))
            (set! data
              (cons (list target dependencies: '() files: files 
                          destination: dest mode: mode) 
                    data))))                      
        ((generated-source-file)
          (fluid-let ((target (check-target (cadr info) data))
                      (src #f)
                      (cbuild #f)
                      (sdeps '())
                      (cdeps '()))
            (for-each compile-extension/program (cddr info))
            (unless cbuild
              (error "generated source files need a custom build step" target))
            (set! genfiles
              (cons (list target dependencies: cdeps source: src 
                          custom: cbuild source-dependencies: sdeps
                          eggfile: eggfile)
                    genfiles))))
        ((c-include)
          (fluid-let ((target (check-target (cadr info) cinc))
                      (dest #f)
                      (files '()))
            (for-each compile-data/include (cddr info))
            (let* ((dest (or dest 
                             (if (eq? mode 'target) 
                                 default-incdir   ; XXX wrong!
                                 (override-prefix "/include" host-incdir))))
                   (dest (normalize-pathname (conc dest "/"))))
              (addfiles (map (cut conc dest <>) files)))
            (set! cinc
              (cons (list target dependencies: '() files: files 
                          destination: dest mode: mode) 
                    cinc))))            
        ((scheme-include)
          (fluid-let ((target (check-target (cadr info) scminc))
                      (dest #f)
                      (files '()))
            (for-each compile-data/include (cddr info))
            (let* ((dest (or dest
                             (if (eq? mode 'target) 
                                 default-sharedir   ; XXX wrong!
                                 (override-prefix "/share" host-sharedir))))
                   (dest (normalize-pathname (conc dest "/"))))
              (addfiles (map (cut conc dest <>) files)))
            (set! scminc 
              (cons (list target dependencies: '() files: files 
                          destination: dest mode: mode) 
                    scminc))))     
        ((program)
          (fluid-let ((target (check-target (cadr info) prgs))
                      (cdeps '())
                      (sdeps '())
                      (cbuild #f)
                      (src #f)
                      (link (if (eq? mode 'target)
                                '(static)
                                (if (null? link) default-program-linkage link)))
                      (lobjs '())
                      (lopts lopts)
                      (oname #f)
                      (opts opts))
            (for-each compile-extension/program (cddr info))
            (let ((dest (if (eq? mode 'target) 
                            default-bindir   ; XXX wrong!
                            (override-prefix "/bin" host-bindir)))
                  ;; Respect install-name if specified
                  (rtarget (or oname target)))
              (addfiles (list (conc dest "/" rtarget exeext)))
	      (set! prgs
		(cons (list target dependencies: cdeps 
                            source: src options: opts
			    link-options: lopts linkage: link 
                            custom: cbuild
			    mode: mode output-file: rtarget 
                            source-dependencies: sdeps
                            link-objects: lobjs
                            eggfile: eggfile)
		      prgs)))))
        (else (compile-common info compile-component))))
    (define (compile-extension/program info)
      (case (car info)
        ((linkage) 
         (set! link (cdr info)))
        ((types-file)
         (set! tfile
           (cond ((null? (cdr info)) #t)
                 ((not (pair? (cadr info)))
                  (arg info 1 name?))
                 (else
                   (set! ptfile #t)
                   (set! tfile
                     (or (null? (cdadr info))
                         (arg (cadr info) 1 name?)))))))
        ((objects)
         (let ((los (map ->string (cdr info))))
           (set! lobjs (append lobjs los))
           (set! cdeps (append cdeps (map ->dep los)))))
        ((inline-file)
         (set! ifile (or (null? (cdr info)) (arg info 1 name?))))
        ((custom-build)
         (set! cbuild (->string (arg info 1 name?))))
        ((csc-options) 
         (set! opts (append opts (cdr info))))
        ((link-options)
         (set! lopts (append lopts (cdr info))))
        ((source)
         (set! src (->string (arg info 1 name?))))
        ((install-name)
         (set! oname (->string (arg info 1 name?))))
        ((modules)
         (set! mods (map library-id (cdr info))))
        ((component-dependencies)
         (set! cdeps (append cdeps (map ->dep (cdr info)))))
        ((source-dependencies)
         (set! sdeps (append sdeps (map ->dep (cdr info)))))
        (else (compile-common info compile-extension/program))))
    (define (compile-common info walk)
      (case (car info)
        ((target)
         (when (eq? mode 'target)
           (for-each walk (cdr info))))
        ((host)
         (when (eq? mode 'host)
           (for-each walk (cdr info))))
        ((error)
         (apply error (cdr info)))
        ((cond-expand)
         (compile-cond-expand info walk))))
    (define (compile-data/include info)
      (case (car info)
        ((destination)
         (set! dest (->string (arg info 1 name?))))
        ((files) 
         (set! files (append files (map ->string (cdr info)))))
        (else (compile-common info compile-data/include))))
    (define (compile-options info)
      (case (car info)
        ((csc-options) (set! opts (append opts (cdr info))))
        ((link-options) (set! lopts (append lopts (cdr info))))
        ((linkage) (set! link (append link (cdr info))))
        (else (error "invalid component-options specification" info))))
    (define (compile-cond-expand info walk)
      (let loop ((clauses (cdr info)))
        (cond ((null? clauses)
               (error "no matching clause in `cond-expand' form" 
                      info))
              ((or (eq? 'else (caar clauses))
                   (check-condition (caar clauses) mode link))
               (for-each walk (cdar clauses)))
              (else (loop (cdr clauses))))))
    (define (->dep x)
      (if (name? x)
          (if (symbol? x) x (string->symbol x))
          (error "invalid dependency" x)))
    (define (compile info)
      (case (car info)
        ((components) (for-each compile-component (cdr info)))
        ((component-options)
         (for-each compile-options (cdr info)))
        (else (compile-common info compile))))
    (define (arg info n #!optional (pred (constantly #t)))
      (when (< (length info) n)
        (error "missing argument" info n))
      (let ((x (list-ref info n)))
        (unless (pred x)
          (error "argument has invalid type" x))
        x))
    (define (name? x) (or (string? x) (symbol? x)))
    (define dep=? equal?)
    (define (filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
            (else (filter pred (cdr lst)))))
    (define (filter-deps name deps)
      (filter (lambda (dep)
                (and (symbol? dep)
                     (or (assq dep exts)
                         (assq dep objs)
                         (assq dep data)
                         (assq dep cinc)
                         (assq dep scminc)
                         (assq dep genfiles)
                         (assq dep prgs)
                         (error "unknown component dependency" dep))))
              deps))
    ;; collect information
    (for-each compile info)
    ;; sort topologically, by dependencies
    (let* ((all (append prgs exts objs genfiles))
           (order (reverse (sort-dependencies      
                            (map (lambda (dep)
                                   (cons (car dep) 
                                         (filter-deps (car dep)
                                                      (get-keyword dependencies: (cdr dep)))))
                              all)
                            dep=?))))
      ;; generate + return build/install commands
      (values
        ;; build commands
        (append-map 
          (lambda (id)
            (cond ((assq id exts) =>
                   (lambda (data)
                     (let ((link (get-keyword linkage: (cdr data)))
                           (mods (get-keyword modules: (cdr data))))
                       (append (if (memq 'dynamic link) 
                                   (list (apply compile-dynamic-extension data))
                                   '())
                               (if (memq 'static link) 
                                   ;; if compiling both static + dynamic, override
                                   ;; modules/types-file/inline-file properties to
                                   ;; avoid generating things twice:
                                   (list (apply compile-static-extension
                                                (if (memq 'dynamic link)
                                                    (cons (car data)
                                                          (append '(modules: #f
                                                                    types-file: #f
                                                                    inline-file: #f)
                                                                  (cdr data)))
                                                    data)))
                                   '())
                               (if (uses-compiled-import-library? mode)
                                   (map (lambda (mod)
                                          (apply compile-import-library
                                             mod (cdr data))) ; override name
                                     mods)
                                   '())))))
                  ((assq id prgs) =>
                   (lambda (data)
                     (let ((link (get-keyword linkage: (cdr data))))
                       (append (if (memq 'dynamic link) 
                                   (list (apply compile-dynamic-program data))
                                   '())
                               (if (memq 'static link) 
                                   (list (apply compile-static-program data))
                                   '())))))
                  ((assq id objs) =>
                   (lambda (data)
                     (let ((link (get-keyword linkage: (cdr data))))
                       (append (if (memq 'dynamic link)
                                   (list (apply compile-dynamic-object data))
                                   '())
                               (if (memq 'static link)
                                   (list (apply compile-static-object data))
                                   '())))))
                  (else
                    (let ((data (assq id genfiles)))
                      (list (apply compile-generated-file data))))))
          order)
        ;; installation commands
        (append
          (append-map
            (lambda (ext)          
              (let ((link (get-keyword linkage: (cdr ext)))
                    (mods (get-keyword modules: (cdr ext))))
                (append
                  (if (memq 'static link)
                      (list (apply install-static-extension ext))
                      '())
                  (if (memq 'dynamic link)
                      (list (apply install-dynamic-extension ext))
                      '())
                  (if (and (memq 'dynamic link)
                           (uses-compiled-import-library? (get-keyword mode: ext)))
                      (map (lambda (mod)
                             (apply install-import-library
                                    mod (cdr ext))) ; override name
                        mods)
                      (map (lambda (mod)
                             (apply install-import-library-source
                                    mod (cdr ext))) ; s.a.
                        mods))
                  (if (get-keyword types-file: (cdr ext))
                      (list (apply install-types-file ext))
                      '())
                  (if (get-keyword inline-file: (cdr ext))
                      (list (apply install-inline-file ext))
                      '()))))
             exts)
          (map (lambda (prg) (apply install-program prg)) prgs)
          (map (lambda (data) (apply install-data data)) data)
          (map (lambda (cinc) (apply install-c-include cinc)) cinc)
          (map (lambda (scminc) (apply install-data scminc)) scminc))
        ;; augmented egg-info
        (append `((installed-files ,@ifiles))
                (if version `((version ,version)) '())
                info)))))


;;; shell code generation - build operations

(define ((compile-static-extension name #!key mode 
                                   source-dependencies
                                   source (options '())
                                   predefined-types eggfile
                                   link-objects modules
                                   custom types-file inline-file)
         srcdir platform)
  (let* ((cmd (qs* (or (custom-cmd custom srcdir platform)
		       default-csc)
		   platform))
         (sname (prefix srcdir name))
         (tfile (qs* (prefix srcdir (conc types-file ".types"))
                     platform))
         (ifile (qs* (prefix srcdir (conc inline-file ".inline"))
                     platform))
         (lfile (qs* (conc sname +link-file-extension+) platform))
         (opts (append (if (null? options)
                           default-static-compilation-options
                           options)
                       (if (and types-file
                                (not predefined-types))
                           (list "-emit-types-file" tfile)
                           '())
                       (if inline-file
                           (list "-emit-inline-file" ifile)
                           '())))
         (out1 (conc sname ".static"))
         (out2 (qs* (target-file (conc out1
                                       (object-extension platform))
                                 mode)
                    platform))
         (out3 (if (null? link-objects)
                   out2
                   (qs* (target-file (conc out1
                                           (archive-extension platform))
                                     mode)
                        platform)))
         (targets (append (list out3 lfile)
                          (maybe types-file tfile)
                          (maybe inline-file ifile)
                          (map (lambda (m)
                                 (qs* (prefix srcdir (conc m ".import.scm"))
                                      platform))
                               (or modules '()))))
         (src (qs* (or source (conc name ".scm")) platform)))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (qs* default-builder platform #t) " "
           (joins targets) " : "
           src " " (qs* eggfile platform) " "
           (if custom cmd "") " "
           (filelist srcdir source-dependencies platform)
           " : " cmd
           (if keep-generated-files " -k" "")
           " -regenerate-import-libraries"
           (if modules " -J" "") " -M"
           " -setup-mode -static -I " srcdir 
           " -emit-link-file " lfile
           (if (eq? mode 'host) " -host" "")
           " -D compiling-extension -c -unit " name
           " -D compiling-static-extension"
           " -C -I" srcdir (arglist opts platform) 
           " " src " -o " out2)
    (when (pair? link-objects)
      (let ((lobjs (filelist srcdir
                             (map (cut conc <> ".static" (object-extension platform))
                               link-objects)
                             platform)))
        (print (qs* default-builder platform #t) " " out3 " : "
               out2 " " lobjs " : "
               (qs* target-librarian platform) " "
               target-librarian-options " " out3 " " out2 " "
               lobjs)))
    (print-end-command platform)))

(define ((compile-dynamic-extension name #!key mode mode
                                    source (options '())
                                    (link-options '())
                                    predefined-types eggfile
                                    link-objects
                                    source-dependencies modules
                                    custom types-file inline-file)
         srcdir platform)
  (let* ((cmd (qs* (or (custom-cmd custom srcdir platform)
                       default-csc)
                   platform))
         (sname (prefix srcdir name))
         (tfile (qs* (prefix srcdir (conc types-file ".types"))
                     platform))
         (ifile (qs* (prefix srcdir (conc inline-file ".inline"))
                     platform))
         (opts (append (if (null? options)
                           default-dynamic-compilation-options
                           options)
                       (if (and types-file
                                (not predefined-types))
                           (list "-emit-types-file" tfile)
                           '())
                       (if inline-file
                           (list "-emit-inline-file" ifile)
                           '())))
         (out (qs* (target-file (conc sname ".so") mode) platform))
         (src (qs* (or source (conc name ".scm")) platform))
         (lobjs (map (lambda (lo)
                       (target-file (conc lo
                                          (object-extension platform))
                                    mode))
                  link-objects))
         (targets (append (list out)
                          (maybe inline-file ifile)
                          (maybe types-file tfile)
                          (map (lambda (m)
                                 (qs* (prefix srcdir (conc m ".import.scm"))
                                      platform))
                            modules))))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (qs* default-builder platform #t) " "
           (joins targets)
           " : "
           src " "
           (qs* eggfile platform) " "
           (if custom cmd "") " "
           (filelist srcdir lobjs platform) " "
           (filelist srcdir source-dependencies platform)
           " : "
           cmd
           (if keep-generated-files " -k" "")
           (if (eq? mode 'host) " -host" "")
           " -D compiling-extension -J -s"
           " -regenerate-import-libraries"
           " -setup-mode -I " srcdir
           " -C -I" srcdir
           (arglist opts platform)
           (arglist link-options platform) " "
           src " "
           (filelist srcdir lobjs platform)
           " -o " out)
    (print-end-command platform)))

(define ((compile-import-library name #!key mode
                                 source-dependencies
                                 (options '()) (link-options '()))
         srcdir platform)
  (let* ((cmd (qs* default-csc platform))
         (sname (prefix srcdir name))
         (opts (if (null? options) 
                   default-import-library-compilation-options
                   options))
         (out (qs* (target-file (conc sname ".import.so") mode)
		   platform))
         (src (qs* (conc name ".import.scm") platform)))
    (print "\n" (qs* default-builder platform #t) " "
           out
           " : "
           src
           (filelist srcdir source-dependencies platform)
           " : "
           cmd
           (if keep-generated-files " -k" "")
           " -setup-mode -s"
           (if (eq? mode 'host) " -host" "")
           " -I " srcdir " -C -I" srcdir
           (arglist opts platform)
           (arglist link-options platform) " "
           src
           " -o " out)
    (print-end-command platform)))

(define ((compile-static-object name #!key mode
                                source-dependencies
                                source (options '())
                                eggfile custom)
         srcdir platform)
  (let* ((cmd (qs* (or (custom-cmd custom srcdir platform)
                       default-csc)
                   platform))
         (sname (prefix srcdir name))
         (ssname (and source (prefix srcdir source)))
         (opts (if (null? options)
                   default-static-compilation-options
                   options))
         (ename (pathname-file eggfile))
         (out (qs* (target-file (conc sname
                                      ".static"
                                      (object-extension platform))
                                mode)
                   platform))
         (src (qs* (or ssname (conc sname ".c")) platform)))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (slashify default-builder platform) " "
           out
           " : "
           (filelist srcdir source-dependencies platform) " "
           src " "
           (qs* eggfile platform) " "
           (if custom cmd "")
           " : "
           cmd
           " -setup-mode -static -I " srcdir
           (if (eq? mode 'host) " -host" "")
           " -c -C -I" srcdir
           (arglist opts platform)
           " " src
           " -o " out)
    (print-end-command platform)))

(define ((compile-dynamic-object name #!key mode mode
                                 source (options '())
                                 eggfile
                                 source-dependencies
                                 custom)
         srcdir platform)
  (let* ((cmd (qs* (or (custom-cmd custom srcdir platform)
                       default-csc)
                   platform))
         (opts (if (null? options)
                   default-dynamic-compilation-options
                   options))
         (sname (prefix srcdir name))
         (ssname (and source (prefix srcdir source)))
         (out (qs* (target-file (conc sname
                                      (object-extension platform))
                                mode)
                   platform))
         (src (qs* (or ssname (conc sname ".c")) platform)))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (slashify default-builder platform) " "
           out
           " : "
           src " "
           (qs* eggfile platform) " "
           (if custom cmd "") " "
           (filelist srcdir source-dependencies platform)
           " : "
           cmd
           (if (eq? mode 'host) " -host" "")
           " -setup-mode -I " srcdir
           " -s -c -C -I" srcdir
           (arglist opts platform)
           " " src
           " -o " out)
    (print-end-command platform)))

(define ((compile-dynamic-program name #!key source mode
                                  (options '()) (link-options '())
                                  source-dependencies
                                  custom eggfile link-objects)
         srcdir platform)
  (let* ((cmd (qs* (or (custom-cmd custom srcdir platform)
		       default-csc)
		   platform))
         (sname (prefix srcdir name))
         (opts (if (null? options) 
                   default-dynamic-compilation-options
                   options))
         (out (qs* (target-file (conc sname
				      (executable-extension platform)) 
				mode)
		  platform))
         (lobjs (map (lambda (lo)
                       (target-file (conc lo
                                          (object-extension platform))
                                    mode))
                  link-objects))
         (src (qs* (or source (conc name ".scm")) platform)))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (qs* default-builder platform #t) " "
           out
           " : "
           src " "
           (qs* eggfile platform) " "
           (if custom cmd "") " "
           (filelist srcdir source-dependencies platform) " "
           (filelist srcdir lobjs platform)
           " : "
           cmd
           (if keep-generated-files " -k" "")
           " -setup-mode"
           (if (eq? mode 'host) " -host" "")
           " -I " srcdir
           " -C -I" srcdir
           (arglist opts platform)
           (arglist link-options platform) " "
           src " "
           (filelist srcdir lobjs platform)
           " -o " out)
    (print-end-command platform)))

(define ((compile-static-program name #!key source
                                 (options '()) (link-options '())
                                 source-dependencies
                                 custom mode eggfile link-objects)
         srcdir platform)
  (let* ((cmd (qs* (or (custom-cmd custom srcdir platform)
		       default-csc)
		   platform))
         (sname (prefix srcdir name))
         (opts (if (null? options) 
                   default-static-compilation-options
                   options))
         (out (qs* (target-file (conc sname
				      (executable-extension platform)) 
				mode)
		  platform))
         (lobjs (map (lambda (lo)
                       (target-file (conc lo
                                          (object-extension platform))
                                    mode))
                  link-objects))
         (src (qs* (or source (conc name ".scm")) platform)))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (qs* default-builder platform #t) " "
           out
           " : "
           src " "
           (qs* eggfile platform) " "
           (if custom cmd "") " "
           (filelist srcdir lobjs platform) " "
           (filelist srcdir source-dependencies platform)
           " : "
           cmd
           (if keep-generated-files " -k" "")
           (if (eq? mode 'host) " -host" "")
           " -static -setup-mode -I " srcdir
           " -C -I"
           srcdir
           (arglist opts platform)
           (arglist link-options platform) " "
           src " "
           (filelist srcdir lobjs platform)
           " -o " out)
    (print-end-command platform)))

(define ((compile-generated-file name #!key source custom
                                 source-dependencies eggfile) 
         srcdir platform)
  (let ((cmd (qs* (custom-cmd custom srcdir platform) platform))
        (out (qs* (or source name) platform)))
    (prepare-custom-command cmd platform)
    (print "\n" (qs* default-builder platform #t)
           " " out " : " cmd " "
           (qs* eggfile platform) " "
           (filelist srcdir source-dependencies platform)
           " : " cmd)
    (print-end-command platform)))


;; installation operations

(define ((install-static-extension name #!key mode output-file
                                   link-objects)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (ext (if (null? link-objects)
                  (object-extension platform)
                  (archive-extension platform)))
         (sname (prefix srcdir name))
         (out (qs* (target-file (conc sname ".static" ext) mode)
		   platform #t))
         (outlnk (qs* (conc sname +link-file-extension+) platform #t))
         (dest (destination-repository mode))
         (dfile (qs* dest platform #t))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
           (qs* (conc dest "/" output-file ext) platform #t))
    (print cmd " " outlnk " " ddir
           (qs* (conc dest "/" output-file +link-file-extension+)
		platform #t))
    (print-end-command platform)))

(define ((install-dynamic-extension name #!key mode (ext ".so")
                                    output-file)
         srcdir platform)
  (let* ((cmd (install-executable-command platform))
         (mkdir (mkdir-command platform))
         (sname (prefix srcdir name))
         (out (qs* (target-file (conc sname ext) mode) platform #t))
         (dest (destination-repository mode))
         (dfile (qs* dest platform #t))
         (ddir (shell-variable "DESTDIR" platform))
         (destf (qs* (conc dest "/" output-file ext) platform #t)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir destf)
    (print-end-command platform)))

(define ((install-import-library name #!key mode)
         srcdir platform)
  ((install-dynamic-extension name mode: mode ext: ".import.so"
                              output-file: name)
   srcdir platform))

(define ((install-import-library-source name #!key mode)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (sname (prefix srcdir name))
         (out (qs* (target-file (conc sname ".import.scm") mode)
		   platform #t))
         (dest (destination-repository mode))
         (dfile (qs* dest platform #t))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
          (qs* (conc dest "/" name ".import.scm") platform #t))
    (print-end-command platform)))

(define ((install-types-file name #!key mode types-file)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (out (qs* (prefix srcdir (conc types-file ".types"))
		   platform #t))
         (dest (destination-repository mode))
         (dfile (qs* dest platform #t))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
          (qs* (conc dest "/" types-file ".types") platform #t))
    (print-end-command platform)))

(define ((install-inline-file name #!key mode inline-file) 
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (out (qs* (prefix srcdir (conc inline-file ".inline"))
		   platform #t))
         (dest (destination-repository mode))
         (dfile (qs* dest platform #t))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
          (qs* (conc dest "/" inline-file ".inline") platform #t))
    (print-end-command platform)))

(define ((install-program name #!key mode output-file) srcdir platform)
  (let* ((cmd (install-executable-command platform))
         (mkdir (mkdir-command platform))
         (ext (executable-extension platform))
         (sname (prefix srcdir name))
         (out (qs* (target-file (conc sname ext) mode) platform #t))
         (dest (if (eq? mode 'target)
                   default-bindir
                   (override-prefix "/bin" host-bindir)))
         (dfile (qs* dest platform #t))
         (ddir (shell-variable "DESTDIR" platform))
         (destf (qs* (conc dest "/" output-file ext) platform #t)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir destf)
    (print-end-command platform)))

(define (install-random-files dest files mode srcdir platform)
  (let* ((fcmd (install-file-command platform))
         (dcmd (copy-directory-command platform))
         (root (string-append srcdir "/"))
         (mkdir (mkdir-command platform))
         (sfiles (map (cut prefix srcdir <>) files))
         (dfile (qs* dest platform #t))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (let-values (((ds fs) (partition directory? sfiles)))
      (for-each
       (lambda (d)
         (let* ((ds (strip-dir-prefix srcdir d))
                (fdir (pathname-directory ds)))
           (when fdir
             (print mkdir " " ddir
                    (qs* (make-pathname dest fdir) platform #t)))
           (print dcmd " " (qs* d platform #t)
                  " " ddir
                  (if fdir
                      (qs* (make-pathname dest fdir) platform #t)
                      dfile))
           (print-end-command platform)))
       ds)
      (when (pair? fs)
        (for-each
          (lambda (f)
            (let* ((fs (strip-dir-prefix srcdir f))
                   (fdir (pathname-directory fs)))
              (when fdir
                (print mkdir " " ddir
                       (qs* (make-pathname dest fdir) platform #t)))
              (print fcmd " " (qs* f platform)
                     " " ddir
                     (if fdir
                         (qs* (make-pathname dest fdir) platform #t)
                         dfile)))
            (print-end-command platform))
          fs)))))

(define ((install-data name #!key files destination mode)
         srcdir platform)
  (install-random-files (or destination
                            (if (eq? mode 'target)
                                default-sharedir
                                (override-prefix "/share"
                                                 host-sharedir)))
                        files mode srcdir platform))

(define ((install-c-include name #!key deps files destination mode) 
         srcdir platform)
  (install-random-files (or destination
                            (if (eq? mode 'target)
                                default-incdir
                                (override-prefix "/include"
                                                 host-incdir)))
                        files mode srcdir platform))


;;; Generate shell or batch commands from abstract build/install operations

(define (generate-shell-commands platform cmds dest srcdir prefix suffix keep)
  (fluid-let ((keep-generated-files keep))
    (with-output-to-file dest
      (lambda ()
        (prefix platform)
        (print (cd-command platform) " " (qs* srcdir platform #t))
        (for-each
          (lambda (cmd) (cmd srcdir platform))
          cmds)
        (suffix platform)))))


;;; affixes for build- and install-scripts

(define ((build-prefix mode name info) platform)
  (case platform
    ((unix)
     (printf #<<EOF
#!/bin/sh~%
set -e
PATH=~a:$PATH
export CHICKEN_CC=~a
export CHICKEN_CXX=~a
export CHICKEN_CSC=~a
export CHICKEN_CSI=~a

EOF
             (qs* default-bindir platform) (qs* default-cc platform)
	     (qs* default-cxx platform) (qs* default-csc platform)
	     (qs* default-csi platform)))
    ((windows)
     (printf #<<EOF
@echo off~%
set PATH=~a;%PATH%
set CHICKEN_CC=~a
set CHICKEN_CXX=~a
set CHICKEN_CSC=~a
set CHICKEN_CSI=~a

EOF
             (qs* default-bindir platform) (qs* default-cc platform)
	     (qs* default-cxx platform) (qs* default-csc platform)
	     (qs* default-csi platform)))))

(define ((build-suffix mode name info) platform)
  (case platform
    ((unix)
     (printf #<<EOF
EOF
             ))
    ((windows)
     (printf #<<EOF
EOF
             ))))

(define ((install-prefix mode name info) platform)
  (case platform
    ((unix)
     (printf #<<EOF
#!/bin/sh~%
set -e

EOF
             ))
    ((windows)
     (printf #<<EOF
@echo off~%
EOF
             ))))

(define ((install-suffix mode name info) platform)
  (let* ((infostr (with-output-to-string (cut pp info)))
         (dcmd (remove-file-command platform))
         (mkdir (mkdir-command platform))
         (dir (destination-repository mode))
         (qdir (qs* dir platform #t))
         (dest (qs* (make-pathname dir name +egg-info-extension+)
		    platform #t))
         (ddir (shell-variable "DESTDIR" platform)))
    (case platform
      ((unix)
       (printf #<<EOF

~a ~a~a
~a ~a~a
cat >~a~a <<ENDINFO
~aENDINFO~%
EOF
               mkdir ddir qdir
               dcmd ddir dest
               ddir dest infostr))
      ((windows)
       (printf #<<EOF

~a ~a~a
echo ~a >~a~a~%
EOF
               mkdir ddir qdir
               (string-intersperse (string-split infostr "\n") "^\n\n")
               ddir dest)))))

;;; some utilities for mangling + quoting

;; The qs procedure quotes for mingw32 or other platforms.  We
;; "normalised" the platform to "windows" in chicken-install, so we
;; have to undo that here again.  It can also convert slashes to
;; backslashes on Windows, which is necessary in many cases when
;; running programs via "cmd".
(define (qs* arg platform #!optional slashify?)
  (let* ((arg (->string arg))
	 (path (if slashify? (slashify arg platform) arg)))
    (qs path (if (eq? platform 'windows) 'mingw32 platform))))

(define (slashify str platform)
  (if (eq? platform 'windows)
      (list->string 
        (map (lambda (c) (if (char=? #\/ c) #\\ c)) (string->list str)))
      str))

(define (prefix dir name)
  (make-pathname dir (->string name)))

;; Workaround for obscure behaviour of "system" on Windows:  If a
;; string starts with double quotes, you _must_ wrap the whole string
;; in an extra set of quotes to avoid the outer quotes being stripped.
;; Don't ask.
(define (system+ str platform)
  (system (if (and (eq? platform 'windows) 
		   (positive? (string-length str))
		   (char=? #\" (string-ref str 0)))
	      (string-append "\"" str "\"")
	      str)))

(define (target-file fname mode)
  (if (eq? mode 'target) (string-append fname ".target") fname))

(define (arglist lst platform)
  (apply conc (map (lambda (x) (conc " " (qs* x platform))) lst)))

(define (filelist dir lst platform)
  (arglist (map (cut prefix dir <>) lst) platform))

(define (shell-variable var platform)
  (case platform
    ((unix) (string-append "${" var "}"))
    ((windows) (string-append "%" var "%"))))

;; NOTE `cmd' must already be quoted for shell
(define (prepare-custom-command cmd platform)
  (unless (eq? 'windows platform)
    (print "chmod +x " cmd)))

(define (custom-cmd custom srcdir platform)
  (and custom (prefix srcdir 
                      (case platform
                        ((windows) (conc custom ".bat"))
                        (else custom)))))

(define (print-end-command platform)
  (case platform
    ((windows) (print "if errorlevel 1 exit /b 1"))))

(define (strip-dir-prefix prefix fname)
  (let* ((plen (string-length prefix))
         (p1 (substring fname 0 plen)))
    (assert (string=? prefix p1) "wrong prefix")
    (substring fname (add1 plen))))

(define (joins strs) (string-intersperse strs " "))

(define (maybe f x) (if f (list x) '()))
