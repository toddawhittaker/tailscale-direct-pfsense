SMOKE_TESTS = tests/smoke.sh
TESTS = \
	tests/smoke.sh \
	tests/test_classify_ping.sh \
	tests/test_config_validation.sh \
	tests/test_cooldown.sh \
	tests/test_daemon_restart_flow.sh \
	tests/test_restart_deferral.sh \
	tests/test_restart_signal_safety.sh \
	tests/test_state_paths.sh \
	tests/test_docs_static.sh \
	tests/test_notify.sh \
	tests/test_peer_state.sh \
	tests/test_installer_static.sh \
	tests/test_rc_static.sh \
	tests/test_uninstaller_static.sh

.PHONY: smoke test

smoke:
	@sh $(SMOKE_TESTS)

test:
	@total=0; passed=0; failed=0; \
	for test_script in $(TESTS); do \
		total=$$((total + 1)); \
		echo "==> $$test_script"; \
		if sh "$$test_script"; then \
			passed=$$((passed + 1)); \
		else \
			failed=$$((failed + 1)); \
		fi; \
	done; \
	if [ "$$failed" -eq 0 ]; then \
		echo "# PASS: $$total test scripts, $$passed passed, $$failed failed"; \
	else \
		echo "# FAIL: $$total test scripts, $$passed passed, $$failed failed"; \
		exit 1; \
	fi
