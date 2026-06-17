package shared

import "testing"

func TestEnvBool(t *testing.T) {
	for _, v := range []string{"1", "true", "on", "TRUE", "True", "ON"} {
		t.Setenv("CP_ENV_BOOL", v)
		if !EnvBool("CP_ENV_BOOL") {
			t.Fatalf("EnvBool(%q) = false, want true", v)
		}
	}
	for _, v := range []string{"", "0", "false", "no", "yes", "2"} {
		t.Setenv("CP_ENV_BOOL", v)
		if EnvBool("CP_ENV_BOOL") {
			t.Fatalf("EnvBool(%q) = true, want false", v)
		}
	}
}

func TestEnvBoolDefault(t *testing.T) {
	if got := EnvBoolDefault("CP_ENV_UNSET", true); !got {
		t.Fatal("unset should return def=true")
	}
	t.Setenv("CP_ENV_BD", "0")
	if EnvBoolDefault("CP_ENV_BD", true) {
		t.Fatal("set-but-falsey should override def")
	}
}

func TestEnvInt(t *testing.T) {
	if got := EnvInt("CP_ENV_UNSET", 7); got != 7 {
		t.Fatalf("unset = %d, want 7", got)
	}
	t.Setenv("CP_ENV_INT", "42")
	if got := EnvInt("CP_ENV_INT", 7); got != 42 {
		t.Fatalf("set = %d, want 42", got)
	}
	t.Setenv("CP_ENV_INT", "notanumber")
	if got := EnvInt("CP_ENV_INT", 7); got != 7 {
		t.Fatalf("unparseable = %d, want def 7", got)
	}
}

func TestEnvStr(t *testing.T) {
	if got := EnvStr("CP_ENV_UNSET", "fallback"); got != "fallback" {
		t.Fatalf("unset = %q, want fallback", got)
	}
	t.Setenv("CP_ENV_STR", "value")
	if got := EnvStr("CP_ENV_STR", "fallback"); got != "value" {
		t.Fatalf("set = %q, want value", got)
	}
}
