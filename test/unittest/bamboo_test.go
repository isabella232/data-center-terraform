package unittest

import (
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
)

func TestBambooVariablesPopulatedWithValidValues(t *testing.T) {
	t.Parallel()

	tfOptions := GenerateTFOptions(BambooCorrectVariables, t, "products/bamboo")
	plan := terraform.InitAndPlanAndShowWithStruct(t, tfOptions)

	// verify Bamboo
	bambooKey := "helm_release.bamboo"
	terraform.RequirePlannedValuesMapKeyExists(t, plan, bambooKey)
	bamboo := plan.ResourcePlannedValuesMap[bambooKey]
	assert.Equal(t, "deployed", bamboo.AttributeValues["status"])
	assert.Equal(t, "bamboo", bamboo.AttributeValues["chart"])
	assert.Equal(t, "https://atlassian.github.io/data-center-helm-charts", bamboo.AttributeValues["repository"])

	// verify Bamboo Agents
	bambooAgentKey := "helm_release.bamboo_agent"
	terraform.RequirePlannedValuesMapKeyExists(t, plan, bambooAgentKey)
	bambooAgent := plan.ResourcePlannedValuesMap[bambooAgentKey]
	assert.Equal(t, "deployed", bambooAgent.AttributeValues["status"])
	assert.Equal(t, "bamboo-agent", bambooAgent.AttributeValues["chart"])
	assert.Equal(t, "https://atlassian.github.io/data-center-helm-charts", bambooAgent.AttributeValues["repository"])
}

// Variables

var BambooCorrectVariables = map[string]interface{}{
	"environment_name": "dummy-environment",
	"namespace":        "dummy-namespace",
	"eks": map[string]interface{}{
		"kubernetes_provider_config": map[string]interface{}{
			"host":                   "dummy-host",
			"token":                  "dummy-token",
			"cluster_ca_certificate": "dummy-certificate",
		},
		"cluster_security_group": "dummy-sg",
	},
	"vpc":                     VpcDefaultModuleVariable,
	"pvc_claim_name":          "dummy_pvc_claimname",
	"db_major_engine_version": "13",
	"ingress":                 map[string]interface{}{},
	"dataset_url":             nil,
	"bamboo_configuration": map[string]interface{}{
		"helm_version": "1.0.0",
		"cpu":          "1",
		"mem":          "1Gi",
		"min_heap":     "256m",
		"max_heap":     "512m",
		"license":      "dummy_license",
	},
	"db_configuration": map[string]interface{}{
		"db_allocated_storage": 5,
		"db_instance_class":    "dummy_db_instance_class",
		"db_iops":              1000,
	},
	"admin_username":      "dummy_admin_username",
	"admin_password":      "dummy_admin_password",
	"admin_display_name":  "dummy_admin_display_name",
	"admin_email_address": "dummy_admin@email_address.com",
	"bamboo_agent_configuration": map[string]interface{}{
		"helm_version": "1.0.0",
		"cpu":          "1",
		"mem":          "1Gi",
		"agent_count":  5,
	},
}
