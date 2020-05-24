;;; monitor.el --- Utilities for monitoring expressions -*- lexical-binding: t -*-

;; Copyright (C) 2016, 2020 Ben Moon
;; Author: Ben Moon <software@guiltydolphin.com>
;; URL: https://github.com/guiltydolphin/monitor
;; Git-Repository: git://github.com/guiltydolphin/monitor.git
;; Created: 2016-08-17
;; Version: 0.4.0
;; Keywords: lisp, monitor, utility
;; Package-Requires: ((dash "2.17.0") (dash-functional "1.2.0") (emacs "25.1"))

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Monitor provides utilities for monitoring expressions.
;; A predicate-based system is used to determine when to run
;; specific functions - not unlike Emacs' built-in hooks (see Info node `Hooks').
;;
;; For example, if we wanted to print "foo" every time the value
;; of (point) changed in the current buffer, we could write:
;;
;;    (monitor-expression-value (point) (lambda () (print "foo")))
;;
;; A (rather convoluted) way of mimicking the functionality of the
;; standard `after-change-major-mode-hook' could be to use the
;; following expression:
;;
;;    (monitor-expression-value major-mode (...))
;;
;; Which would run whenever the value of `major-mode' changed.

;;; Code:

(require 'dash)
(require 'dash-functional)
(require 'eieio)


;;;;;;;;;;;;;;;;;;
;;;;; Errors ;;;;;
;;;;;;;;;;;;;;;;;;


(define-error 'monitor--missing-required-option
  "Missing required option(s)")

(define-error 'monitor--does-not-inherit-base-monitor-class
  "The class does not inherit from `monitor--monitor'")


;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; Customization ;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;


(defgroup monitor nil
  "Monitor expressions."
  :group 'lisp
  :prefix 'monitor-)


;;;;;;;;;;;;;;;;;;;
;;;;; Helpers ;;;;;
;;;;;;;;;;;;;;;;;;;


(defun monitor--funcall (fn &rest args)
  "Call FN as a function with remaining ARGS, use the last arg as list of args.

Thus (monitor--funcall #'fn 'a '(b c)) is the same as (funcall #'fn 'a 'b 'c).

Returns the value FN returns."
  (funcall (-applify fn) (-concat (-drop-last 1 args) (car (-take-last 1 args)))))

(defun monitor--require-monitor-obj (obj)
  "Get the monitor associated with OBJ.

This fails if OBJ does not satisfy `monitorp'."
  (cl-check-type obj monitorp)
  obj)

(defun monitor--parse-keyword-value-args (args &optional special-keys)
  "Parse ARGS as a series of keyword value pairs.

If SPECIAL-KEYS is specified, it should be a series of keyword
symbols to keep separate from the main keyword list, and will be
returned as a separate element.

The result is in the format (keyword-args special-args non-keyword-args)."
  (let (keys specials)
    (while (keywordp (car args))
      (let ((k (pop args))
            (v (pop args)))
        (if (memq k special-keys)
            (progn (push k specials) (push v specials))
          (push k keys)
          (push v keys))))
    (list (nreverse keys) (nreverse specials) args)))

(defun monitor--expand-define-args (args)
  "Parse ARGS as a monitor definition argument list."
  (pcase-let* ((`(,keys ,specials ,args) (monitor--parse-keyword-value-args args '(:class)))
               (class (plist-get specials :class)))
    (list (if (eq (car-safe class) 'quote) (cadr class) class) keys args)))

(defun monitorp (monitor)
  "Return non-NIL if MONITOR is a monitor."
  (monitor--monitor--eieio-childp monitor))

(defun monitor--enabled-p (monitor)
  "T if MONITOR is enabled."
  (slot-value monitor 'enabled))

(defun monitor--disabled-p (monitor)
  "T if MONITOR is disabled."
  (not (monitor--enabled-p monitor)))

(defun monitor--parse-specs (spec-class specs owner)
  "Parse SPECS as specifications for SPEC-CLASS with given OWNER."
  (mapcar
   (lambda (spec)
     (let* ((sclass (or
                     (monitor--get-class-for-alias spec-class (car spec))
                     (error "%s is not known to be a %s" (car spec) spec-class)))
            (args (cdr spec))
            (instance (apply sclass (monitor--parse-spec sclass args))))
       (oset instance owner owner)
       (monitor--setup instance)
       instance)) specs))

(cl-defgeneric monitor--get-class-for-alias (class alias)
  "Retrieve the class associated with the symbol ALIAS, for a given CLASS.")

(cl-defmethod monitor--get-class-for-alias ((class (subclass monitor--spec)) alias)
  (or (and (slot-boundp class 'alias) (eq (oref-default class alias) alias) class)
      (and (eq alias (eieio-class-name class)) class)
      (-any (lambda (c) (monitor--get-class-for-alias c alias)) (eieio-class-children class))))

(defun monitor--parse-listeners (listener-spec owner)
  "Parse LISTENER-SPEC into appropriate listeners for the given OWNER."
  (monitor--parse-specs 'monitor--listener listener-spec owner))

(defun monitor--parse-guards (guard-spec owner)
  "Parse GUARD-SPEC into appropriate guards for the given OWNER."
  (monitor--parse-specs 'monitor--guard guard-spec owner))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; Classes - Interfaces ;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defclass monitor--spec ()
  ((alias :documentation "Optional alias for the spec."
          :allocation :class))
  :documentation "Abstract class for specifications.")

(defclass monitor--can-enable ()
  ((enabled :initform nil
            :type booleanp
            :documentation "Non-NIL if the instance is currently enabled.

Do not modify this value manually, instead use `monitor-enable' and `monitor-disable' on the parent monitor."))
  :documentation "Abstract class for things that can be enabled/disabled.")

(defclass monitor--can-trigger ()
  ((guard-trigger
    :initarg :guard-trigger
    :initform nil
    :documentation "Specification used to guard triggering.")
   (on-trigger :initarg :on-trigger
               :type functionp
               :documentation "What to do when triggered."))
  :abstract t
  :documentation "Abstract class for things that can trigger.")


;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; Classes - Guards ;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defclass monitor--guard (monitor--can-enable monitor--spec)
  ((owner :documentation "Object that this guard is guarding."))
  :abstract t
  :documentation "Base class for guards which can be used to refine when other components can trigger or activate.")

(defclass monitor--expression-value-guard (monitor--guard)
  ((expr :initarg :expr
         :documentation "Expression to monitor. It's probably best to keep this free of side-effects.")
   (pred :initarg :pred
         :type functionp
         :documentation "Function used to compare the previous and current vaue of the expression.

The function is passed the old and new values and arguments, and should return non-NIL if the monitor should trigger.")
   (value :documentation "Last known value of `:expr' (don't set this manually).")
   (alias :initform 'expression-value))
  :documentation "Guard which allows triggering only if an expression has reached a desired state.")


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; Classes - Listeners ;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defclass monitor--listener (monitor--can-enable monitor--can-trigger monitor--spec)
  ((owner :type monitorp
          :documentation "The monitor associated with this listener. Do not modify this value manually."))
  :abstract t
  :documentation "Abstract base class for all listeners.")

(defclass monitor--hook-listener (monitor--listener)
  ((hook :initarg :hook
         :documentation "Hook variable to target.")
   (alias :initform 'hook))
  :documentation "Listener for triggering on hooks.")


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; Classes - Monitors ;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defclass monitor--monitor (monitor--can-enable monitor--can-trigger)
  ((trigger-on :initarg :trigger-on
               :initform nil
               :documentation "Specification for listeners that should trigger the monitor.")
   (listeners :initform nil))
  :documentation "Base class for all monitors.")


;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; Class methods ;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;


;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Enabling and disabling ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(cl-defgeneric monitor--enable (obj)
  "Enable OBJ.

Note that you should only use this when implementing the method behaviour via `cl-defmethod', if you actually want to enable the monitor, use `monitor-enable' instead.")

(cl-defgeneric monitor--disable (obj)
  "Disable OBJ.

Note that you should only use this when implementing the method behaviour via `cl-defmethod', if you actually want to disable the monitor, use `monitor-disable' instead.")

(defun monitor-enable (monitor)
  "Enable MONITOR."
  (let ((m (monitor--require-monitor-obj monitor)))
    (unless (monitor--enabled-p m) (monitor--enable m))))

(defun monitor-disable (monitor)
  "Disable MONITOR."
  (let ((m (monitor--require-monitor-obj monitor)))
    (unless (monitor--disabled-p m) (monitor--disable m))))


;;; can-enable (abstract)


(cl-defmethod monitor--enable :after ((obj monitor--can-enable))
  (oset obj enabled t))

(cl-defmethod monitor--disable :after ((obj monitor--can-enable))
  (oset obj enabled nil))


;;; can-trigger (abstract)


(cl-defmethod monitor--enable :after ((obj monitor--can-trigger))
  (dolist (guard (oref obj guard-trigger))
    (monitor--enable guard)))

(cl-defmethod monitor--disable :after ((obj monitor--can-trigger))
  (dolist (guard (oref obj guard-trigger))
    (monitor--disable guard)))


;;; Monitor (monitor)


(cl-defmethod monitor--enable ((obj monitor--monitor))
  (dolist (listener (oref obj listeners))
    (monitor--enable listener)))

(cl-defmethod monitor--disable ((obj monitor--monitor))
  (dolist (listener (oref obj listeners))
    (monitor--disable listener)))


;;; Listener (listener)


(cl-defmethod monitor--enable :after ((obj monitor--listener))
  (dolist (guard (oref obj guard-trigger))
    (monitor--enable guard)))

(cl-defmethod monitor--disable :after ((obj monitor--listener))
  (dolist (guard (oref obj guard-trigger))
    (monitor--disable guard)))


;;; Hook (listener)


(defun monitor--hook-build-hook-fn (obj)
  "Build a form suitable for adding to a hook for the OBJ."
  (lambda () (monitor--trigger--trigger obj)))

(cl-defmethod monitor--enable ((obj monitor--hook-listener))
  (add-hook (oref obj hook) (monitor--hook-build-hook-fn obj)))

(cl-defmethod monitor--disable ((obj monitor--hook-listener))
  (remove-hook (oref obj hook) (monitor--hook-build-hook-fn obj)))


;;; Expression-value (guard)


(cl-defmethod monitor--enable ((obj monitor--expression-value-guard))
  (oset obj value (eval (oref obj expr))))

(cl-defmethod monitor--disable ((obj monitor--expression-value-guard))
  (slot-makeunbound obj 'value))


;;;;;;;;;;;
;; Setup ;;
;;;;;;;;;;;


(cl-defgeneric monitor--setup (obj)
  "Initialize OBJ.

This method is called when an instance is created with
`monitor-define-monitor', so it's a good place to put any
validation (e.g., checking for missing options) and
initialization you want to apply to all new instances.

You should usually either combine this method with `:before' or
`:after' (see `cl-defmethod'), or call `cl-call-next-method' in
the body.")

(defun monitor--validate-required-options (obj props)
  "Check that OBJ provides each option in PROPS, fail otherwise."
  (let ((missing-opts))
    (dolist (prop props)
      (unless (slot-boundp obj prop)
        (push prop missing-opts)))
    (unless (null missing-opts)
      (signal 'monitor--missing-required-option (nreverse missing-opts)))))


;;; can-trigger (abstract)


(cl-defmethod monitor--setup :after ((obj monitor--can-trigger))
  (let ((guard-trigger (monitor--parse-guards (oref obj guard-trigger) obj)))
    (oset obj guard-trigger guard-trigger)))


;;; Monitor (monitor)


(cl-defmethod monitor--setup ((obj monitor--monitor))
  (let ((trigger-on (monitor--parse-listeners (oref obj trigger-on) obj)))
    (oset obj trigger-on trigger-on))
  (oset obj listeners (oref obj trigger-on)))


;;; Listener (listener)


(cl-defmethod monitor--setup :after ((obj monitor--listener))
  ;; unless an :on-trigger was manually specified, we set this to call the owner
  (unless (slot-boundp obj 'on-trigger)
    (oset obj on-trigger (lambda () (monitor--trigger--trigger (oref obj owner))))))

(cl-defmethod monitor--setup ((_ monitor--listener)))


;;; Hook (listener)


(cl-defmethod monitor--setup :before ((obj monitor--hook-listener))
  "We require the :hook argument to be bound."
  (monitor--validate-required-options obj '(:hook)))


;;; Guard (guard)


(cl-defmethod monitor--setup ((_ monitor--guard))
  "No additional setup required for base guard.")


;;; Expression-value (guard)


(cl-defmethod monitor--setup ((obj monitor--expression-value-guard))
  "We require the `:expr' and `:pred' arguments to be bound."
  (monitor--validate-required-options obj '(:expr :pred)))


;;;;;;;;;;;;;;;;;
;; Predication ;;
;;;;;;;;;;;;;;;;;


(cl-defgeneric monitor--test-predicate (obj)
  "Return T if we should proceed based on OBJ.")


;;; List


(cl-defmethod monitor--test-predicate ((obj list))
  "Lists require all sub-predicates to succeed."
  (-all-p #'monitor--test-predicate obj))


;;; Expression-value (guard)


(cl-defmethod monitor--test-predicate ((obj monitor--expression-value-guard))
  (let* ((expr (oref obj expr))
         (old (oref obj value))
         (new (eval expr)))
    (oset obj value new)
    (funcall (oref obj pred) old new)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Specification parsing ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;


(cl-defgeneric monitor--parse-spec (obj args)
  "Specify how to parse ARGS as a specification for OBJ.")


;;; Listener (listener)


(cl-defmethod monitor--parse-spec ((_ (subclass monitor--listener)) args)
  args)


;;; Hook (listener)


(cl-defmethod monitor--parse-spec ((_ (subclass monitor--hook-listener)) args)
  (pcase-let* ((`(,keys ,specials ,args)
                (monitor--parse-keyword-value-args args '(:hook)))
               (hook (if (plist-member specials :hook)
                         (plist-get specials :hook)
                       (pop args))))
    (when hook (setq keys (plist-put keys :hook hook)))
    (-concat keys args)))


;;; Guard (guard)


(cl-defmethod monitor--parse-spec ((_ (subclass monitor--guard)) args)
  args)


;;;;;;;;;;;;;;;;
;; Triggering ;;
;;;;;;;;;;;;;;;;


(cl-defgeneric monitor--trigger--trigger (obj &optional args)
  "This method determines how to handle triggering a monitor, i.e., the moment the monitor becomes instantaneously active.")


;;; can-trigger (abstract)


(cl-defmethod monitor--trigger--trigger ((obj monitor--can-trigger) &optional args)
  "Run the `:on-trigger' function of the owner of OBJ with ARGS as arguments.

Only triggers if the predicate in `:trigger-pred' returns non-NIL."
  (when (monitor--test-predicate (oref obj guard-trigger))
    (monitor--run (oref obj on-trigger) args)))


;;;;;;;;;;;;;
;; Running ;;
;;;;;;;;;;;;;


(cl-defgeneric monitor--run (obj &optional args))


;;; functions


(cl-defmethod monitor--run ((obj (head closure)) &optional args)
  (monitor--funcall obj args))

(cl-defmethod monitor--run ((obj (head lambda)) &optional args)
  (monitor--funcall obj args))

(cl-defmethod monitor--run ((obj function) &optional args)
  (monitor--funcall obj args))

(cl-defmethod monitor--run ((obj subr) &optional args)
  (monitor--funcall obj args))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; Creating monitors ;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defun monitor-create (&rest args)
  "Create a new monitor.

ARGS is a series of keyword-value pairs.  Each key has to be a
keyword symbol, either `:class' or a keyword argument supported
by the constructor of that class.  If no class is specified, it
defaults to `monitor--monitor'."
  (declare (indent 1))
  (pcase-let* ((`(,class ,slots _)
                (monitor--expand-define-args args))
               (class (or class 'monitor--monitor)))
    (unless (child-of-class-p class 'monitor--monitor)
      (signal 'monitor--does-not-inherit-base-monitor-class class))
    (let ((obj (monitor--funcall class slots)))
      (monitor--setup obj)
      obj)))


(provide 'monitor)
;;; monitor.el ends here
