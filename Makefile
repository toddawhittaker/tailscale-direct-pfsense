SMOKE_TESTS = tests/smoke.sh
TESTS = \
	tests/smoke.sh \
	tests/test_classify_ping.sh \
	tests/test_cooldown.sh \
	tests/test_daemon_restart_flow.sh \
	tests/test_installer_static.sh

.PHONY: smoke test

smoke:
	@sh $(SMOKE_TESTS)

test:
	@for test_script in $(TESTS); do \
		echo "==> $$test_script"; \
		sh "$$test_script" || exit 1; \
	done
