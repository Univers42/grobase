package push

import (
	"context"
	"fmt"
	"net"
	"syscall"
)

// dialFor returns the transport's DialContext: the operator-allowlisted host the
// transport asks for (PUSH_SSRF_ALLOW_HOSTS, read live by hostAllowlisted, the
// same check guardTarget runs) is dialed through allowlistedDialControl, every
// other host through pinnedDialControl. The choice is made per dial, so each
// redirect hop is judged by its own host.
func dialFor(pinned, allowlisted *net.Dialer) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		if host, _, err := net.SplitHostPort(addr); err == nil && hostAllowlisted(host) {
			return allowlisted.DialContext(ctx, network, addr)
		}
		return pinned.DialContext(ctx, network, addr)
	}
}

// pinnedDialControl is the dial-time half of the SSRF guard: it receives the
// concrete post-resolution address the kernel is about to connect to and refuses
// any private/loopback/link-local/metadata IP, so a rebinding DNS name cannot
// slip an internal address past guardTarget's earlier lookup.
func pinnedDialControl(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); ip != nil && isBlockedIP(ip) {
		return fmt.Errorf("%w: refusing to dial blocked address %s", ErrBlockedTarget, host)
	}
	return nil
}

// allowlistedDialControl lets an allowlisted host reach loopback and private
// space (an in-cluster sink) but still refuses the cloud metadata addresses: no
// push sink lives there, and an allowlisted name whose container is down can be
// resolved by the host's resolver to anything.
func allowlistedDialControl(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); ip != nil && isMetadataIP(ip) {
		return fmt.Errorf("%w: refusing to dial metadata address %s", ErrBlockedTarget, host)
	}
	return nil
}

// isMetadataIP reports link-local addresses (169.254.0.0/16 and fe80::/10, which
// hold the AWS/GCP/Azure metadata endpoint, IPv4-mapped forms included), AWS's
// IPv6 endpoint fd00:ec2::254 and Alibaba's 100.100.100.200.
func isMetadataIP(ip net.IP) bool {
	if ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
		return true
	}
	return ip.Equal(net.ParseIP("fd00:ec2::254")) || ip.Equal(net.ParseIP("100.100.100.200"))
}
