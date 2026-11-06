package main

import rego.v1

# Fixed rule: runs even if the AI scores the plan 0.
deny contains msg if {
	rc := input.resource_changes[_]
	"delete" in rc.change.actions
	rc.type == "kubernetes_namespace_v1"
	msg := sprintf("%s would be deleted; namespaces are protected", [rc.address])
}
