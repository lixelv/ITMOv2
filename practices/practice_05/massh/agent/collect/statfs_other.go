//go:build !linux

package collect

import "errors"

// Statfs is only implemented on Linux, the one platform the Agent runs on.
func Statfs(string) (total, free uint64, err error) { return 0, 0, errors.ErrUnsupported }
