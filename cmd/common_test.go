package cmd

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
)

func Test_parseClusterAndProjectID(t *testing.T) {
	tt := []struct {
		name            string
		inputID         string
		expectedCluster string
		expectedProject string
		expectedErr     string
	}{
		{
			name:            "simple parsing",
			inputID:         "local:p-12345",
			expectedCluster: "local",
			expectedProject: "p-12345",
		},
		{
			name:            "simple parsing with downstream cluster",
			inputID:         "c-12345:p-12345",
			expectedCluster: "c-12345",
			expectedProject: "p-12345",
		},
		{
			name:        "wrong cluster name returns an error",
			inputID:     "cocal:p-12345",
			expectedErr: "Unable to extract clusterid and projectid",
		},
		{
			name:        "short cluster name returns an error",
			inputID:     "c-123:p-123",
			expectedErr: "Unable to extract clusterid and projectid",
		},
		{
			name:        "empty ID returns an error",
			inputID:     "",
			expectedErr: "Unable to extract clusterid and projectid",
		},
		{
			name:            "no-local valid cluster ID and project",
			inputID:         "c-m-12345678:p-12345",
			expectedCluster: "c-m-12345678",
			expectedProject: "p-12345",
		},
		{
			name:        "short cluster ID returns an error",
			inputID:     "c-m-123:p-12345",
			expectedErr: "Unable to extract clusterid and projectid",
		},
	}

	for _, tc := range tt {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			cluster, project, err := parseClusterAndProjectID(tc.inputID)
			fmt.Println(err)

			if tc.expectedErr != "" {
				assert.ErrorContains(t, err, tc.expectedErr)
				assert.Empty(t, cluster)
				assert.Empty(t, project)
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tc.expectedCluster, cluster)
				assert.Equal(t, tc.expectedProject, project)
			}
		})
	}
}

func Test_convertSnakeCaseKeysToCamelCase(t *testing.T) {
	tt := []struct {
		name     string
		input    map[string]interface{}
		expected map[string]interface{}
	}{
		{
			name:     "",
			input:    map[string]interface{}{"foo_bar": "hello"},
			expected: map[string]interface{}{"fooBar": "hello"},
		},
		{
			name:     "",
			input:    map[string]interface{}{"fooBar": "hello"},
			expected: map[string]interface{}{"fooBar": "hello"},
		},
		{
			name:     "",
			input:    map[string]interface{}{"foobar": "hello", "some_key": "valueUnmodified", "bar-baz": "bar-baz"},
			expected: map[string]interface{}{"foobar": "hello", "someKey": "valueUnmodified", "bar-baz": "bar-baz"},
		},
		{
			name: "",
			input: map[string]interface{}{
				"foo_bar":       "hello",
				"backup_config": map[string]interface{}{"hello_world": true},
				"config_id":     123,
			},
			expected: map[string]interface{}{
				"fooBar":       "hello",
				"backupConfig": map[string]interface{}{"helloWorld": true},
				"configId":     123,
			},
		},
	}

	for _, tc := range tt {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			convertSnakeCaseKeysToCamelCase(tc.input)
			assert.Equal(t, tc.expected, tc.input)
		})
	}
}
