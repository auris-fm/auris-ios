SOURCE := podcasts/VoiceControl/VoiceSharing/VoiceSharingCaptureAllowance.swift
PROBE := artifacts/capture-allowance/probe
.PHONY: probe test-host
probe:
	mkdir -p artifacts/capture-allowance
	xcrun swiftc $(SOURCE) scripts/tests/capture-allowance/Probe.swift -o $(PROBE)
test-host: probe
	python3 scripts/tests/capture-allowance/check.py $(PROBE)
.PHONY: owner-controls test-owner
owner-controls:
	mkdir -p artifacts/capture-allowance
	xcrun swiftc $(SOURCE) scripts/tests/capture-allowance/OwnerControls.swift -o artifacts/capture-allowance/owner-controls
test-owner: owner-controls
	artifacts/capture-allowance/owner-controls
