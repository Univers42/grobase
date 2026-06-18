package cmek

// cmekErr is the package's const error type, so every sentinel is a typed
// constant (no package-level var) while preserving errors.Is + %w wrapping.
type cmekErr string

func (e cmekErr) Error() string { return string(e) }
