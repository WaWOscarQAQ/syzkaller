// Copyright 2024 syzkaller project authors. All rights reserved.
// Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.

package manager

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/google/syzkaller/pkg/mgrconfig"
	"github.com/stretchr/testify/require"
)

func TestReadSeedInputs(t *testing.T) {
	seedDir := t.TempDir()
	for _, name := range []string{"first", "second"} {
		require.NoError(t, os.WriteFile(filepath.Join(seedDir, name), []byte(name), 0o600))
	}
	tests := []struct {
		name      string
		seedFiles []string
		want      []string
		wantErr   string
	}{
		{name: "all seeds", want: []string{"first", "second"}},
		{name: "no seeds", seedFiles: []string{}},
		{name: "selected seed", seedFiles: []string{"second"}, want: []string{"second"}},
		{name: "missing seed", seedFiles: []string{"missing"}, wantErr: `seed "missing" does not exist`},
		{name: "path instead of name", seedFiles: []string{"../first"}, wantErr: "is not a file name"},
		{name: "absolute path", seedFiles: []string{"/first"}, wantErr: "is not a file name"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			output := make(chan *input, 2)
			err := readSeedInputs(&mgrconfig.Config{SeedFiles: tc.seedFiles},
				seedDir, filepath.Join("sys", "test"), output)
			if tc.wantErr != "" {
				require.ErrorContains(t, err, tc.wantErr)
				return
			}
			require.NoError(t, err)
			close(output)
			var got []string
			for inp := range output {
				require.True(t, inp.IsSeed)
				require.Equal(t, filepath.Base(inp.Path), string(inp.Data))
				got = append(got, filepath.Base(inp.Path))
			}
			require.ElementsMatch(t, tc.want, got)
		})
	}
}

func TestRequires(t *testing.T) {
	{
		requires := parseRequires([]byte("# requires: manual arch=amd64"))
		require.True(t, checkArch(requires, "amd64"))
		require.False(t, checkArch(requires, "riscv64"))
	}
	{
		requires := parseRequires([]byte("# requires: -arch=arm64 manual -arch=riscv64"))
		require.True(t, checkArch(requires, "amd64"))
		require.False(t, checkArch(requires, "riscv64"))
	}
}

func TestMatchRequirements(t *testing.T) {
	tests := []struct {
		name     string
		props    map[string]bool
		requires map[string]bool
		want     bool
	}{
		{"positive match", map[string]bool{"nested": true}, map[string]bool{"nested": true}, true},
		{"missing positive match", map[string]bool{}, map[string]bool{"nested": true}, false},
		{"negative match (absent)", map[string]bool{}, map[string]bool{"threaded": false}, true},
		{
			"negative match (false)",
			map[string]bool{"threaded": false},
			map[string]bool{"threaded": false},
			true,
		},
		{"negative mismatch", map[string]bool{"threaded": true}, map[string]bool{"threaded": false}, false},
		{
			"key-value match",
			map[string]bool{"vendor=intel": true},
			map[string]bool{"vendor=intel": true},
			true,
		},
		{
			"key-value mismatch",
			map[string]bool{"vendor=amd": true},
			map[string]bool{"vendor=intel": true},
			false,
		},
		{
			"multiple requirements (all match)",
			map[string]bool{"arch=amd64": true, "vendor=intel": true, "nested": true},
			map[string]bool{"arch=amd64": true, "vendor=intel": true, "nested": true},
			true,
		},
		{
			"multiple requirements (one mismatch)",
			map[string]bool{"arch=amd64": true, "vendor=amd": true, "nested": true},
			map[string]bool{"arch=amd64": true, "vendor=intel": true, "nested": true},
			false,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			require.Equal(t, tc.want, MatchRequirements(tc.props, tc.requires))
		})
	}
}
