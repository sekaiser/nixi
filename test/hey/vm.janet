#!/usr/bin/env janet

(use judge)
(use hey/vm)

(deftest ip/link-local?
  (test (ip/link-local? "169.254.0.1") true)
  (test (ip/link-local? " 169.254.164.83\n") true)
  (test (ip/link-local? "169.253.255.255") false)
  (test (ip/link-local? "192.168.178.131") false))
