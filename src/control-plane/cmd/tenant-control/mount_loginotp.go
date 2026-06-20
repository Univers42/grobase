package main

import (
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/loginotp"
)

// mountLoginOTP mounts the email login-OTP second factor (EMAIL_OTP_ENABLED): a
// 6-digit code mailed to the account address, verified back in the terminal. The
// routes are public (pre-login; the email + the code are the authentication). OFF ⇒
// no /v1/auth/otp/* routes (404 = byte-parity).
func (b *bootCtx) mountLoginOTP() {
	if !config.EnvBool("EMAIL_OTP_ENABLED") {
		b.log.Info("email login OTP disabled (EMAIL_OTP_ENABLED off) — /v1/auth/otp/* not mounted")
		return
	}
	loginotp.Mount(b.mux, loginotp.New(b.db, b.log))
	b.log.Info("email login OTP enabled (/v1/auth/otp/request|verify) — EMAIL_OTP_ENABLED")
}
