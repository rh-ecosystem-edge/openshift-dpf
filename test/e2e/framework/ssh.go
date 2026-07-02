package framework

import (
	"fmt"
	"os"
	"time"

	"golang.org/x/crypto/ssh"
)

// SSHClient wraps an SSH connection to a remote host.
type SSHClient struct {
	client *ssh.Client
	host   string
}

// NewSSHClient opens an SSH connection using a private key file.
func NewSSHClient(host, user, privateKeyPath string) (*SSHClient, error) {
	keyData, err := os.ReadFile(privateKeyPath)
	if err != nil {
		return nil, fmt.Errorf("read SSH key %s: %w", privateKeyPath, err)
	}
	signer, err := ssh.ParsePrivateKey(keyData)
	if err != nil {
		return nil, fmt.Errorf("parse SSH key: %w", err)
	}
	cfg := &ssh.ClientConfig{
		User:            user,
		Auth:            []ssh.AuthMethod{ssh.PublicKeys(signer)},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(), //nolint:gosec // internal infra only
		Timeout:         30 * time.Second,
	}
	c, err := ssh.Dial("tcp", fmt.Sprintf("%s:22", host), cfg)
	if err != nil {
		return nil, fmt.Errorf("SSH dial %s: %w", host, err)
	}
	return &SSHClient{client: c, host: host}, nil
}

// Run executes cmd on the remote host and returns combined stdout+stderr.
// Returns an error if the command exits non-zero.
func (s *SSHClient) Run(cmd string) (string, error) {
	sess, err := s.client.NewSession()
	if err != nil {
		return "", fmt.Errorf("new SSH session on %s: %w", s.host, err)
	}
	defer sess.Close()
	out, err := sess.CombinedOutput(cmd)
	if err != nil {
		return string(out), fmt.Errorf("SSH run %q on %s: %w\nOutput: %s", cmd, s.host, err, out)
	}
	return string(out), nil
}

// Close closes the underlying SSH connection.
func (s *SSHClient) Close() error {
	return s.client.Close()
}

// RebootHost issues a non-blocking `sudo reboot` on the remote host.
// The connection is expected to drop immediately.
func (s *SSHClient) RebootHost() error {
	sess, err := s.client.NewSession()
	if err != nil {
		return fmt.Errorf("SSH session for reboot: %w", err)
	}
	// nohup ensures the reboot runs even if the session drops
	_ = sess.Run("sudo nohup sh -c 'sleep 1 && reboot' &>/dev/null &")
	sess.Close()
	return nil
}
