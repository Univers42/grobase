package smtpclient

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestImplicitTLS(t *testing.T) {
	cases := []struct {
		port   int
		secure bool
		want   bool
	}{
		{465, false, true},
		{465, true, true},
		{587, true, true},
		{587, false, false},
		{1025, false, false},
	}
	for _, c := range cases {
		if got := (Config{Port: c.port, Secure: c.secure}).ImplicitTLS(); got != c.want {
			t.Errorf("port=%d secure=%v: got %v, want %v", c.port, c.secure, got, c.want)
		}
	}
}

func TestFromEnv(t *testing.T) {
	t.Setenv("SMTP_HOST", "smtp.example")
	t.Setenv("SMTP_PORT", "465")
	t.Setenv("SMTP_SECURE", "")
	t.Setenv("SMTP_USER", "u")
	t.Setenv("SMTP_PASS", "p")
	t.Setenv("EMAIL_FROM", "")
	t.Setenv("MAIL_PRO", "pro@x.test")
	c := FromEnv("MAIL_PRO")
	if c.Host != "smtp.example" || c.Port != 465 || c.User != "u" || c.Pass != "p" || c.From != "pro@x.test" || !c.ImplicitTLS() {
		t.Fatalf("unexpected config %+v", c)
	}
	t.Setenv("EMAIL_FROM", "a@x.test")
	if got := FromEnv("MAIL_PRO").From; got != "a@x.test" {
		t.Errorf("EMAIL_FROM must win over fallbacks, got %q", got)
	}
}

// fakeServer is a minimal SMTP server. tlsFirst wraps accepted conns in TLS;
// startTLS advertises and honours STARTTLS; auth advertises AUTH PLAIN.
type fakeServer struct {
	ln       net.Listener
	cert     tls.Certificate
	pool     *x509.CertPool
	tlsFirst bool
	startTLS bool
	auth     bool

	mu       sync.Mutex
	data     string
	upgraded bool
}

func selfSigned(t *testing.T) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, pool
}

func newFake(t *testing.T, tlsFirst, startTLS, auth bool) *fakeServer {
	t.Helper()
	cert, pool := selfSigned(t)
	f := &fakeServer{cert: cert, pool: pool, tlsFirst: tlsFirst, startTLS: startTLS, auth: auth}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f.ln = ln
	t.Cleanup(func() { _ = ln.Close() })
	go f.serve()
	return f
}

func (f *fakeServer) config() Config {
	port := f.ln.Addr().(*net.TCPAddr).Port
	return Config{Host: "localhost", Port: port, Secure: f.tlsFirst, RootCAs: f.pool, Timeout: 5 * time.Second}
}

func (f *fakeServer) serve() {
	for {
		raw, err := f.ln.Accept()
		if err != nil {
			return
		}
		go f.handle(raw)
	}
}

func (f *fakeServer) handle(raw net.Conn) {
	defer raw.Close()
	tlsCfg := &tls.Config{Certificates: []tls.Certificate{f.cert}, MinVersion: tls.VersionTLS12}
	var conn net.Conn = raw
	if f.tlsFirst {
		conn = tls.Server(raw, tlsCfg)
	}
	r := bufio.NewReader(conn)
	write := func(s string) { _, _ = conn.Write([]byte(s + "\r\n")) }
	write("220 fake ESMTP")
	inData := false
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		line = strings.TrimRight(line, "\r\n")
		if inData {
			if line == "." {
				inData = false
				write("250 queued")
				continue
			}
			f.mu.Lock()
			f.data += line + "\n"
			f.mu.Unlock()
			continue
		}
		cmd := strings.ToUpper(line)
		switch {
		case strings.HasPrefix(cmd, "EHLO"):
			write("250-fake")
			if f.startTLS && !f.upgraded {
				write("250-STARTTLS")
			}
			if f.auth {
				write("250-AUTH PLAIN")
			}
			write("250 OK")
		case cmd == "STARTTLS":
			write("220 go ahead")
			conn = tls.Server(raw, tlsCfg)
			r = bufio.NewReader(conn)
			f.mu.Lock()
			f.upgraded = true
			f.mu.Unlock()
			write = func(s string) { _, _ = conn.Write([]byte(s + "\r\n")) }
		case strings.HasPrefix(cmd, "AUTH"):
			write("235 ok")
		case strings.HasPrefix(cmd, "DATA"):
			inData = true
			write("354 go")
		case cmd == "QUIT":
			write("221 bye")
			return
		default:
			write("250 OK")
		}
	}
}

func (f *fakeServer) got() (string, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.data, f.upgraded
}

func TestSendImplicitTLSSpeaksTLSFirst(t *testing.T) {
	f := newFake(t, true, false, false)
	// f.config() sets Secure because the port is ephemeral, not 465.
	if err := Send(f.config(), "a@x.test", "b@x.test", []byte("Subject: hi\r\n\r\nbody\r\n")); err != nil {
		t.Fatalf("send over implicit TLS: %v", err)
	}
	if data, _ := f.got(); !strings.Contains(data, "body") {
		t.Errorf("server did not receive the body, got %q", data)
	}
}

func TestSendImplicitTLSAgainstPlainServerFails(t *testing.T) {
	f := newFake(t, false, false, false)
	c := f.config()
	c.Secure = true
	c.Timeout = 2 * time.Second
	if err := Send(c, "a@x.test", "b@x.test", []byte("x")); err == nil {
		t.Fatal("a TLS-first client must not complete against a plain server")
	}
}

func TestSendSTARTTLSWhenOffered(t *testing.T) {
	f := newFake(t, false, true, true)
	c := f.config()
	c.User, c.Pass = "u", "secret"
	if err := Send(c, "a@x.test", "b@x.test", []byte("Subject: s\r\n\r\nhello\r\n")); err != nil {
		t.Fatalf("send via STARTTLS: %v", err)
	}
	data, upgraded := f.got()
	if !upgraded || !strings.Contains(data, "hello") {
		t.Errorf("upgraded=%v data=%q", upgraded, data)
	}
}

func TestSendPlainWhenNoSTARTTLS(t *testing.T) {
	f := newFake(t, false, false, false)
	if err := Send(f.config(), "a@x.test", "b@x.test", []byte("Subject: s\r\n\r\nplain\r\n")); err != nil {
		t.Fatalf("plain send: %v", err)
	}
	data, upgraded := f.got()
	if upgraded || !strings.Contains(data, "plain") {
		t.Errorf("upgraded=%v data=%q", upgraded, data)
	}
}

func TestSendUserWithoutServerAuthIsAnError(t *testing.T) {
	for _, tlsFirst := range []bool{false, true} {
		f := newFake(t, tlsFirst, false, false)
		c := f.config()
		c.User, c.Pass = "u", "hunter2-secret"
		err := Send(c, "a@x.test", "b@x.test", []byte("x"))
		if err == nil {
			t.Fatalf("tlsFirst=%v: user set but server has no AUTH must fail", tlsFirst)
		}
		if strings.Contains(err.Error(), c.Pass) {
			t.Errorf("error leaks the password: %v", err)
		}
	}
}

func TestPingUsesTLSOnImplicitPort(t *testing.T) {
	f := newFake(t, true, false, false)
	if err := Ping(f.config()); err != nil {
		t.Fatalf("ping over implicit TLS: %v", err)
	}
	plain := newFake(t, false, false, false)
	if err := Ping(plain.config()); err != nil {
		t.Fatalf("plain ping: %v", err)
	}
}

func TestSendBlackholeHonoursDeadline(t *testing.T) {
	for _, secure := range []bool{false, true} {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		go func() {
			for {
				conn, err := ln.Accept()
				if err != nil {
					return
				}
				defer conn.Close() // held open, never written to
			}
		}()
		c := Config{Host: "127.0.0.1", Port: ln.Addr().(*net.TCPAddr).Port, Secure: secure, Timeout: 300 * time.Millisecond}
		start := time.Now()
		done := make(chan error, 1)
		go func() { done <- Send(c, "a@x.test", "b@x.test", []byte("x")) }()
		select {
		case err := <-done:
			if err == nil {
				t.Errorf("secure=%v: blackhole must error", secure)
			}
			if el := time.Since(start); el > 3*time.Second {
				t.Errorf("secure=%v: took %v", secure, el)
			}
		case <-time.After(5 * time.Second):
			t.Errorf("secure=%v: Send did not return within the deadline", secure)
		}
		_ = ln.Close()
	}
}

func TestErrorNeverContainsPassword(t *testing.T) {
	pass := "p4ss-w0rd-" + strconv.Itoa(int(time.Now().Unix()))
	c := Config{Host: "127.0.0.1", Port: 1, User: "u", Pass: pass, Timeout: time.Second}
	if err := Send(c, "a@x.test", "b@x.test", []byte("x")); err == nil || strings.Contains(err.Error(), pass) {
		t.Fatalf("dial error must exist and hide the password: %v", err)
	}
	// A server that echoes the secret back in its rejection is scrubbed too.
	echo := c.scrub(errString("535 bad credentials " + pass))
	if strings.Contains(echo.Error(), pass) || !strings.Contains(echo.Error(), "[redacted]") {
		t.Errorf("scrub failed: %v", echo)
	}
}

type errString string

func (e errString) Error() string { return string(e) }
