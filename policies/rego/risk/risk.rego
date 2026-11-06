package main

import rego.v1

threshold := 70

deny contains msg if {
	input.risk_score >= threshold
	msg := sprintf("AI risk score %d is at or above %d: %v", [input.risk_score, threshold, input.reasons])
}
