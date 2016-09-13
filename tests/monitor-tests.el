;;; monitor-tests.el
;;; Code:

(require 'ert)
(require 'monitor)

(ert-deftest monitor-test-monitor-p ()
  "Tests for `monitor-p'."
  (let ((monitor-symbol (make-symbol "monitor-test-monitor-p-tvar")))
  ; initially, we don't expect it to be a monitor.
  (should (eq nil (monitor-p monitor-symbol)))
  (monitor--define-monitor monitor-symbol 'default "Test monitor.")
  ; now we've created a monitor, it should recognize it as one
  (should-not (eq nil (monitor-p monitor-symbol)))
  (monitor--remove-monitor monitor-symbol)
  ; now it is no longer a monitor
  (should (eq nil (monitor-p monitor-symbol)))))

(provide 'monitor-tests)
;;; monitor-tests.el ends here
