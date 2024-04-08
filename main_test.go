package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func Test(t *testing.T) {
	tt := []struct {
		name           string
		input          []string
		expectedOutput []string
		expectedErr    string
	}{
		{
			name:           "multiple simple flags",
			input:          []string{"rancher", "run", "--debug", "-itd"},
			expectedOutput: []string{"rancher", "run", "--debug", "-i", "-t", "-d"},
		},
		{
			name:           "multiple flags with key value flag",
			input:          []string{"rancher", "run", "--debug", "-itf=b"},
			expectedOutput: []string{"rancher", "run", "--debug", "-i", "-t", "-f=b"},
		},
		{
			name:        "invalid char in flags",
			input:       []string{"rancher", "run", "--debug", "-itd#"},
			expectedErr: "invalid input # in flag",
		},
		{
			name:           "single key value flag",
			input:          []string{"rancher", "run", "--debug", "-f=b"},
			expectedOutput: []string{"rancher", "run", "--debug", "-f=b"},
		},
		{
			name:        "key value flag with missing key",
			input:       []string{"rancher", "run", "--debug", "-=b"},
			expectedErr: "invalid input with '-' and '=' flag",
		},
		{
			name:           "single dash arg-flag",
			input:          []string{"rancher", "run", "--debug", "-"},
			expectedOutput: []string{"rancher", "run", "--debug", "-"},
		},
	}

	for _, tc := range tt {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			parsedArgs, err := parseArgs(tc.input)

			if tc.expectedErr != "" {
				assert.ErrorContains(t, err, tc.expectedErr)
				assert.Nil(t, parsedArgs)
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tc.expectedOutput, parsedArgs)
			}
		})
	}
}
