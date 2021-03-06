;;; -*- Mode: Lisp; Package: Analysis-Facility -*-
;;;
;;; Sccs Id @(#)af-dependency.lisp	1.4 9/28/89");
;;; ******************************************************************* ;;;
;;;          (c) Copyright 1989 by Carnegie Mellon University.          ;;;
;;;                        All rights reserved.                         ;;;
;;;         This code was written as part of the Ergo project.          ;;;
;;;  If you want to use this code or any Ergo software, please contact  ;;;
;;;			Frank Pfenning (fp@cs.cmu.edu)			;;;
;;; ******************************************************************* ;;;

;;; AF-DEPENDENCY.LISP - Ergo Analysis Facility 
;;;
;;; ABSTRACT
;;; 
;;;; Compile-time dependency analysis and code generation.
;;;
;;; AUTHOR
;;;
;;;	William Maddox
;;;
;;; HISTORY
;;;
;;;     07-17-86         rln    Initial development and release
;;;     07-22-87         rln    Reimplementation

(in-package :analysis-facility)
(use-package '("AF-RUNTIME-LIB"))

;;; The variable *CODE* accumulates the code descriptors generated by SCHEDULE.

(defvar *code* nil)

(defmacro emit (code)
  `(push ,code *code*))

;;; The variable *DP-RESOLVED* accumulates the attributes whose dependencies
;;; have been resolved.

(defvar *dp-resolved* nil)

(defmacro resolved (attr &optional (code nil))
  `(push (cons ,attr ,code) *dp-resolved*))
(defmacro resolvedp (attr)
  `(find ,attr *dp-resolved* :key #'car))
(defmacro resolved-code (attr)
  `(cdr (find ,attr *dp-resolved* :key #'car)))

(defvar *dp-used* nil)

(defmacro used (attr)
  `(push ,attr *dp-used*))

;;; Demand the graph for an attribute.  Code (descriptors) are emitted to bind
;;; the graph to the attribute name.  PENDING is a list of attribute names for
;;; which an unsatisfied demand currently exists.  If a pending attribute is
;;; demanded, then a linear sequence of bindings satisfying all demands does not
;;; exist, and a forward reference node and fixup must be generated.  The result
;;; of this function should be used to reference the demanded graph value.  It is
;;; usually the same as NAME, but may be the name of a forward node.

;;; The evaluation of synthesized attributes is demand driven.
;;; However, inherited attributes are ALWAYS passed down.

(defun demand (env pending name &optional (gencode t))
  (let ((entry (lookup env name)))
    (if (member name pending)
	(abox-error "Illegal circularity OR multiple pass required for (~A)"
		    name)
	(let ((defn (attrdef-definition entry)))
	  (cond ((resolvedp name)
		 ;; Definition is attribute itself, dependencies already resolved
		 (when (and gencode (dp-visit-p defn))
		   (let ((code (resolved-code name))
			 (syn (dp-visit-synthesized defn)))
		     (setf (cd-visit-results code)
			   (mapargs syn (cons name (cd-visit-results code))))))
		 name)
		((symbolp defn)
		 ;; Definition is attribute itself, dependencies already resolved
		 (used defn) defn)
		((dp-eval-p defn)
		 ;; Definition is an expression, as in a WHERE clause
		 (let* ((expr   (dp-eval-expression defn))
			(args   (dp-eval-attrsused  defn)))
		   (demand-all env (cons name pending) args gencode)
		   (if gencode
		       (emit (make-cd-eval :attribute  name
					   :expression expr ))))
		 (resolved name)
		 name)
		((dp-eval-iterate-p defn)
		 ;; Definition is an expression, as in a WHERE clause
		 ;; declared iterate
		 (let ((expr   (dp-eval-iterate-expression defn))
		       (args   (dp-eval-iterate-attrsused  defn))
		       (init   (dp-eval-iterate-initial    defn))
		       (test   (dp-eval-iterate-test       defn)))
		   (let ((iexpr (dp-eval-expression init))
			 (iargs (dp-eval-attrsused  init))
			 (argcode (schedule-iterate (changeinit env (list name)) args)))
		     (demand-all env (cons name pending) iargs gencode)
		     (if gencode
			 (emit (make-cd-eval-iterate
				:attribute  name
				:expression expr
				:argcode    argcode
				:initial    iexpr
				:test       test)))))
		 (resolved name)
		 name)
		((dp-visit-p defn)
		 ;; Attribute defined by visit to child node
		 (let ((nont  (dp-visit-nonterminal defn))
		       (inh   (dp-visit-inherited   defn))
		       (syn   (dp-visit-synthesized defn))
		       (opt   (dp-visit-optsort     defn))
		       (pos   (dp-visit-position    defn))
		       (fam   (dp-visit-family      defn))
		       (tlist (dp-visit-tlist       defn)))
		   (let ((*dp-resolved* *dp-resolved*))	; check for circularities
		     (demand-all env (cons name pending) inh nil))
		   (let ((code (if gencode
				   (make-cd-visit :function  nont
						  :arguments inh
						  :results   (mapargs syn (list name))
						  :optsort   opt
						  :position  pos
						  :family    fam
						  :tlist     tlist )
				   nil)))
		     (if gencode (emit code))
		     (dolist (attr syn) (resolved attr code)))
		   name))
		((dp-iterate-p defn)
		 ;; Attribute defined by iterate
		 (let ((nont  (dp-iterate-nonterminal defn))
		       (inh   (dp-iterate-inherited   defn))
		       (syn   (dp-iterate-synthesized defn))
		       (opt   (dp-iterate-optsort     defn))
		       (pos   (dp-iterate-position    defn))
		       (fam   (dp-iterate-family      defn))
		       (init  (dp-iterate-initial     defn))
		       (test  (dp-iterate-test        defn)))
		   (let ((expr (dp-eval-expression init))
			 (args (dp-eval-attrsused init))
			 (argcode (schedule-iterate (changeinit env syn) inh)))
		     (demand-all env (cons name pending) args gencode)
		     (if gencode
			 (emit (make-cd-iterate :function  nont
						:arguments inh
						:argcode   argcode
						:results   syn
						:optsort   opt
						:position  pos
						:family    fam
						:initial   expr
						:test      test )))
		     name)))
		(t (error "Internal error - bogus definition ~S" defn)))))))


;;; Demand a list of attributes, returning a list of names to which the
;;; resulting graphs will be bound.

(defun demand-all (env pending attrs &optional (gencode t))		 
  (do ((x attrs (cdr x))
       (y nil (cons (demand env pending (car x) gencode) y)))
      ((null x) (nreverse y))))

;;; Schedule visits and evaluations in the construction of the graph.
;;; ENV is the attribute definition environment.  WANT is the list of
;;; attribute names whose graphs are to be constructed, i.e. the synthesized
;;; attributes of the production at hand.  CONSTRAINTS is the list of 
;;; constraints for which checks must made at evaluation time.  The result
;;; of SCHEDULE is a list of code descriptors which defines the binding of
;;; all attributes in the WANT list and the entry of check records on the
;;; check list for the CONSTRAINTS.

(defun schedule (env want &optional (constraints nil))
  (let ((*code* nil)
	(*dp-resolved* nil))
    ;; generate code to check constraints
    (dolist (const constraints)
      (let* ((predicate (car const))
	     (pexp      (dp-eval-expression predicate))
	     (pargs     (dp-eval-attrsused predicate))
	     (epargs    (demand-all env nil pargs))
	     (message   (cdr const))
	     (mexp      (dp-eval-expression message))
	     (margs     (dp-eval-attrsused message))
	     (emargs    (demand-all env nil margs)))
	(declare (ignore epargs emargs))
	(emit (make-cd-check :predicate pexp :message mexp))))
    ;; generate code to evaluate graphs for synthesized attributes
    (dolist (attr want) (demand env nil attr))
    ;; code list generated by emit macro is backwards
    (nreverse *code*)))

(defun demand-iterate (env pending name &optional (gencode t))
  (let ((entry (lookup env name)))
    (if (member name pending)
	(abox-error "Illegal circularity OR multiple pass required for (~A)"
		    name)
	(let ((defn (attrdef-definition entry)))
	  (cond ((resolvedp name)
		 ;; Definition is attribute itself, dependencies resolved
		 name)
		((symbolp defn)
		 ;; Definition is attribute itself, dependencies resolved
		 (used defn) defn)
		((dp-eval-p defn)
		 ;; Definition is an expression, as in a WHERE clause
		 (let* ((expr   (dp-eval-expression defn))
			(args   (dp-eval-attrsused  defn)))
		   (demand-all-iterate env (cons name pending) args gencode)
		   (if gencode
		       (emit (make-cd-eval :attribute  name
					   :expression expr ))))
		 (resolved name)
		 name)
		((dp-eval-iterate-p defn)
		 ;; Definition is an expression, as in a WHERE clause
		 ;; declared iterate
		 (let ((expr   (dp-eval-iterate-expression defn))
		       (args   (dp-eval-iterate-attrsused  defn))
		       (init   (dp-eval-iterate-initial    defn))
		       (test   (dp-eval-iterate-test       defn)))
		   (let ((iexpr (dp-eval-expression init))
			 (iargs (dp-eval-attrsused  init))
			 (argcode (schedule-iterate
				   (changeinit env (list name)) args (cons name pending))))
		     (demand-all env (cons name pending) iargs gencode)
		     (if gencode
			 (emit (make-cd-eval-iterate
				:attribute  name
				:expression expr
				:argcode    argcode
				:initial    iexpr
				:test       test)))))
		 (resolved name)
		 name)
		((dp-visit-p defn)
		 ;; Attribute defined by visit to child node
		 (let ((nont  (dp-visit-nonterminal defn))
		       (inh   (dp-visit-inherited   defn))
		       (syn   (dp-visit-synthesized defn))
		       (opt   (dp-visit-optsort     defn))
		       (pos   (dp-visit-position    defn))
		       (fam   (dp-visit-family      defn))
		       (tlist (dp-visit-tlist       defn)))
		   (let ((argcode (schedule-iterate (changeinit env syn) inh (cons name pending))))
		     (dolist (attr syn) (resolved attr))
		     (if gencode
			 (emit (make-cd-visit :function  nont
					      :arguments inh
					      :argcode   argcode
					      :results   syn
					      :optsort   opt
					      :position  pos
					      :family    fam
					      :tlist     tlist ))))
		   name))
		((dp-iterate-p defn)
		 ;; Attribute defined by iterate
		 (let ((nont  (dp-iterate-nonterminal defn))
		       (inh   (dp-iterate-inherited   defn))
		       (syn   (dp-iterate-synthesized defn))
		       (opt   (dp-iterate-optsort     defn))
		       (pos   (dp-iterate-position    defn))
		       (fam   (dp-iterate-family      defn))
		       (init  (dp-iterate-initial     defn))
		       (test  (dp-iterate-test        defn)))
		   (let ((expr (dp-eval-expression init))
			 (args (dp-eval-attrsused init))
			 (argcode (schedule-iterate (changeinit env syn) inh (cons name pending))))
		     (demand-all env (cons name pending) args gencode)
		     (if gencode
			 (emit (make-cd-iterate :function  nont
						:arguments inh
						:argcode   argcode
						:results   syn
						:optsort   opt
						:position  pos
						:family    fam
						:initial   expr
						:test      test )))
		     name)))
		(t (error "Internal error - bogus definition ~S" defn)))))))


;;; Demand a list of attributes, returning a list of names to which the
;;; resulting graphs will be bound.

(defun demand-all-iterate (env pending attrs &optional (gencode t))		 
  (dolist (attr attrs)
    (demand-iterate env pending attr gencode)))

(defun schedule-iterate (env want &optional (pending nil))
  (let ((*code* nil)
	(*dp-resolved* nil))
    ;; generate code to evaluate graphs for synthesized attributes
    (dolist (attr want) (demand-iterate env pending attr))
    ;; code list generated by emit macro is backwards
    (nreverse *code*)))



;;; Generate Lisp code in which the expression BODY appears within code to
;;; bind attribute names to their graphs as indicated by the code descriptors
;;; (DESCRIPTORS) produced by SCHEDULE.

(defun encode (descriptors body sort context)
  (if (null descriptors)
      body
      (let ((form (car descriptors)))
	(cond ((cd-eval-p form)
	       (let ((attr (cd-eval-attribute  form))
		     (expr (cd-eval-expression form)))
		 `(let ((,attr ,expr))
		    ,(encode (cdr descriptors) body sort context))))
	      ((cd-eval-iterate-p form)
	       (let ((attr (cd-eval-iterate-attribute  form))
		     (expr (cd-eval-iterate-expression form))
		     (argcode (cd-eval-iterate-argcode form))
		     (init (cd-eval-iterate-initial    form))
		     (test (cd-eval-iterate-test       form)))
		 `(let ((,attr
			 (rt-get-iterate
			  ,attr ,init
			  ,(encode-iterate argcode expr sort context)
			  ,test)))
		    ,(encode (cdr descriptors) body sort context))))
	      ((cd-visit-p form)
	       (let ((child-sort (cd-visit-function  form))
		     (args       (cd-visit-arguments form))
		     (res        (cd-visit-results   form))
		     (opt        (cd-visit-optsort   form))
		     (pos        (cd-visit-position  form))
		     (synfam     (family-synfam (cd-visit-family form)))
		     (confam     (family-confam (cd-visit-family form)))
		     (tlist      (cd-visit-tlist     form)))
		 (cond (opt
			`(rt-mvb (,opt ,@res)
			      (rt-get-synfam-argn-opt
			       ,synfam ,sort ,child-sort ,pos %term% ,@context)
			      ,(encode (cdr descriptors) body sort context)))
		       (tlist
			(multiple-value-bind (bbf bbl lst) (list-attrs tlist)
			  (let* ((fin-body (encode (cdr descriptors) body sort context))
				 (lst (get-syn-names lst))
				 (lst-body
				  (if lst
				      `(rt-mvb ,(mapargs res lst)
					    (rt-get-synfam-list
					     ,synfam ,sort ,child-sort %term% ,@context)
					    ,fin-body)
				      fin-body))
				 (inh (get-inh-names tlist))
				 (bbf (get-syn-names bbf))
				 (bbf-body
				  (if bbf
				      `(rt-mvb ,(mapargs res bbf)
					   (if (zerop (rt-nchild %term%))
					       (rt-mvb ,(cons-undef inh)
						   (rt-delta-confam ,confam ,sort -1 %term% ,@context)
						 (rt-vls ,@(mapmates res bbf tlist)))
					       (rt-get-synfam-argn
						,synfam ,sort ,child-sort ,(first-child '%term%) %term% ,@context))
					    ,lst-body)
				      lst-body))
				 (inh (get-inh-names tlist))
				 (bbl (get-syn-names bbl))
				 (bbl-body
				  (if bbl
				      `(rt-mvb ,(mapargs res bbl)
					   (if (zerop (rt-nchild %term%))
					       (rt-mvb ,(cons-undef inh)
						   (rt-delta-confam ,confam ,sort -1 %term% ,@context)
						 (rt-vls ,@(mapmates res bbl tlist)))
					    (rt-get-synfam-argn
					     ,synfam ,sort ,child-sort ,(last-child '%term%) %term% ,@context))
					    ,bbf-body)
				      bbf-body)))
			    bbl-body)))
		       (t
			`(rt-mvb ,res
				 (rt-get-synfam-argn ,synfam ,sort ,child-sort ,pos %term% ,@context)
				 ,(encode (cdr descriptors) body sort context))))))
	      ((cd-iterate-p form)
	       (let ((child-sort (cd-iterate-function  form))
		     (args       (cd-iterate-arguments form))
		     (argcode    (cd-iterate-argcode   form))
		     (res        (cd-iterate-results   form))
		     (opt        (cd-iterate-optsort   form))
		     (pos        (cd-iterate-position  form))
		     (synfam     (family-synfam (cd-iterate-family form)))
		     (initial    (cd-iterate-initial   form))
		     (test       (cd-iterate-test      form)))
		 (cond (opt
			`(rt-mvb (,opt ,@res)
			     (rt-get-iterate-opt
			      %term% ,@res ,initial
			      ,(encode-iterate argcode
				`(rt-get-synfam
				  ,synfam ,child-sort
				  ,(term-selector `%term% pos)
				  #+termocc ,(termocc-selector `%termocc% pos)
				  ,@args)
				sort context) ,test )
			   ,(encode (cdr descriptors) body sort context)))
		       (t
			`(rt-mvb ,res (rt-get-iterate
				    ,@res ,initial
				    ,(encode-iterate argcode
				     `(rt-get-synfam
				       ,synfam ,child-sort
				       ,(term-selector `%term% pos)
				       #+termocc ,(termocc-selector `%termocc% pos)
				       ,@args)
				     sort context) ,test)
			   ,(encode (cdr descriptors) body sort context))))))
	      ((cd-check-p form)
	       (let ((predicate (cd-check-predicate form))
		     (message   (cd-check-message   form))
		     (args      (cd-check-args      form)))
		 `(progn
		   ,(constraint-check predicate message args)
		   ,(encode (cdr descriptors) body sort context))))
	      (t (error "Internal error - invalid code descriptor ~S" form))))))

(defun encode-iterate (descriptors body sort context)
  (if (null descriptors)
      body
      (let ((form (car descriptors)))
	(cond ((cd-eval-p form)
	       (let ((attr (cd-eval-attribute  form))
		     (expr (cd-eval-expression form)))
		 `(let ((,attr ,expr))
		    ,(encode-iterate (cdr descriptors) body sort context))))
	      ((cd-eval-iterate-p form)
	       (let ((attr (cd-eval-iterate-attribute  form))
		     (expr (cd-eval-iterate-expression form))
		     (argcode (cd-eval-iterate-argcode form))
		     (init (cd-eval-iterate-initial    form))
		     (test (cd-eval-iterate-test       form)))
		 `(let ((,attr
			 (rt-get-iterate ,attr ,init
			  ,(encode-iterate argcode expr sort context)
			  ,test)))
		    ,(encode-iterate (cdr descriptors) body sort context))))
	      ((cd-visit-p form)
	       (let ((child-sort (cd-visit-function  form))
		     (args       (cd-visit-arguments form))
		     (argcode    (cd-visit-argcode   form))
		     (res        (cd-visit-results   form))
		     (opt        (cd-visit-optsort   form))
		     (pos        (cd-visit-position  form))
		     (synfam     (family-synfam (cd-visit-family form)))
		     (confam     (family-confam (cd-visit-family form)))
		     (tlist      (cd-visit-tlist     form)))
		 (cond (opt
			`(rt-mvb (,opt ,@res)
			      ,(encode-iterate argcode
				 `(rt-get-synfam-opt
				   ,synfam ,child-sort ,(term-selector '%term% pos)
				   #+termocc ,(termocc-selector '%termocc% pos)
				   ,@args) sort context)
			      ,(encode-iterate (cdr descriptors) body sort context)))
		       (tlist (abox-error "Iterate attribute may not have list dependency"))
		       (t
			`(rt-mvb ,res
			  ,(encode-iterate argcode
			    `(rt-get-synfam ,synfam ,child-sort ,(term-selector '%term% pos)
					    #+termocc ,(termocc-selector '%termocc% pos)
					    ,@args) sort context)
			  ,(encode-iterate (cdr descriptors) body sort context))))))
	      ((cd-iterate-p form)
	       (let ((child-sort (cd-iterate-function  form))
		     (args       (cd-iterate-arguments form))
		     (argcode    (cd-iterate-argcode   form))
		     (res        (cd-iterate-results   form))
		     (opt        (cd-iterate-optsort   form))
		     (pos        (cd-iterate-position  form))
		     (synfam     (family-synfam (cd-iterate-family form)))
		     (initial    (cd-iterate-initial   form))
		     (test       (cd-iterate-test      form)))
		 (cond (opt
			`(rt-mvb (,opt ,@res)
			     (rt-get-iterate-opt
			      %term% ,@res ,initial
			      ,(encode-iterate
				argcode
				`(rt-get-synfam
				  ,synfam ,child-sort
				  ,(term-selector `%term% pos)
				  #+termocc ,(termocc-selector `%termocc% pos)
				  ,@args)
				sort context) ,test )
			   ,(encode-iterate (cdr descriptors) body sort context)))
		       (t
			`(rt-mvb ,res (rt-get-iterate
				    ,@res ,initial
				   ,(encode-iterate
				     argcode
				     `(rt-get-synfam
				       ,synfam ,child-sort
				       ,(term-selector `%term% pos)
				       #+termocc ,(termocc-selector `%termocc% pos)
				       ,@args)
				     sort context) ,test)
			   ,(encode-iterate (cdr descriptors) body sort context))))))
	      ((cd-check-p form)
	       (error "Internal error - invalid code descriptor ~S" form))
	      (t (error "Internal error - invalid code descriptor ~S" form))))))

