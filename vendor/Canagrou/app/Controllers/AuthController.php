<?php

declare(strict_types=1);

namespace App\Controllers;

use App\Core\Controller;
use App\Core\Session;
use App\Core\Validator;
use App\Core\Mailer;
use App\Core\RateLimiter;
use App\Models\User;

class AuthController extends Controller
{
    private User $user;

    public function __construct()
    {
        $this->user = new User();
    }

    // ─── Registration ──────────────────────────────────────────

    public function registerForm(array $params = []): void
    {
        if (Session::isAuthenticated()) {
            $this->redirect('/editor');
        }
        $this->render('auth/register', ['_title' => 'Sign Up — Camagru']);
    }

    public function register(array $params = []): void
    {
        // Rate limit: 3 registrations per 5 minutes
        RateLimiter::enforce('register', 3, 300);

        $username = $this->input('username');
        $email    = $this->input('email');
        $password = $this->input('password');
        $confirm  = $this->input('password_confirm');

        $data = array_merge($_POST, $this->jsonBody());
        $v = new Validator($data);
        $v->required('username', 'Username')
          ->minLength('username', 3, 'Username')
          ->maxLength('username', 20, 'Username')
          ->alphanumeric('username', 'Username')
          ->required('email', 'Email')
          ->email('email', 'Email')
          ->required('password', 'Password')
          ->passwordStrength('password', 'Password')
          ->required('password_confirm', 'Password confirmation')
          ->matches('password_confirm', 'password', 'Password confirmation');

        if ($v->fails()) {
            if ($this->wantsJson()) {
                $this->json(['error' => $v->firstError()], 422);
                return;
            }
            Session::flash('error', $v->firstError());
            Session::flash('old_input', ['username' => $username, 'email' => $email]);
            $this->redirect('/register');
            return;
        }

        // Check uniqueness
        if ($this->user->findByUsername($username)) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'This username is already taken.'], 409);
                return;
            }
            Session::flash('error', 'This username is already taken.');
            Session::flash('old_input', ['username' => $username, 'email' => $email]);
            $this->redirect('/register');
            return;
        }

        if ($this->user->findByEmail($email)) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'An account with this email already exists.'], 409);
                return;
            }
            Session::flash('error', 'An account with this email already exists.');
            Session::flash('old_input', ['username' => $username, 'email' => $email]);
            $this->redirect('/register');
            return;
        }

        // Create user
        $userId = $this->user->register($username, $email, $password);
        $user = $this->user->findById($userId);

        // Send verification email
        Mailer::sendVerification($email, $username, $user['verification_token']);

        if ($this->wantsJson()) {
            $this->json(['success' => true, 'redirect' => '/login', 'message' => 'Account created! Please check your email to verify your account.']);
            return;
        }

        Session::flash('success', 'Account created! Please check your email to verify your account.');
        $this->redirect('/login');
    }

    // ─── Email Verification ────────────────────────────────────

    public function verify(array $params = []): void
    {
        $token = $this->query('token');

        if (empty($token)) {
            Session::flash('error', 'Invalid verification link.');
            $this->redirect('/login');
            return;
        }

        $user = $this->user->findByVerificationToken($token);

        if (!$user) {
            Session::flash('error', 'Invalid or expired verification link.');
            $this->redirect('/login');
            return;
        }

        $this->user->verify((int)$user['id']);
        Session::flash('success', 'Email verified successfully! You can now log in.');
        $this->redirect('/login');
    }

    // ─── Login ─────────────────────────────────────────────────

    public function loginForm(array $params = []): void
    {
        if (Session::isAuthenticated()) {
            $this->redirect('/editor');
        }
        $this->render('auth/login', ['_title' => 'Login — Camagru']);
    }

    public function login(array $params = []): void
    {
        // Rate limit: 5 login attempts per minute
        RateLimiter::enforce('login', 5, 60);

        $username = $this->input('username');
        $password = $this->input('password');

        $v = new Validator(array_merge($_POST, $this->jsonBody()));
        $v->required('username', 'Username')
          ->required('password', 'Password');

        if ($v->fails()) {
            if ($this->wantsJson()) {
                $this->json(['error' => $v->firstError()], 422);
                return;
            }
            Session::flash('error', $v->firstError());
            $this->redirect('/login');
            return;
        }

        $user = $this->user->findByUsername($username);

        if (!$user || !password_verify($password, $user['password'])) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Invalid username or password.'], 401);
                return;
            }
            Session::flash('error', 'Invalid username or password.');
            Session::flash('old_input', ['username' => $username]);
            $this->redirect('/login');
            return;
        }

        if (!$user['verified']) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Please verify your email before logging in. Check your inbox.'], 403);
                return;
            }
            Session::flash('error', 'Please verify your email before logging in. Check your inbox.');
            $this->redirect('/login');
            return;
        }

        // Regenerate session ID to prevent fixation
        Session::regenerate();
        Session::set('user_id', $user['id']);
        Session::set('username', $user['username']);
        RateLimiter::reset('login');

        if ($this->wantsJson()) {
            $this->json(['success' => true, 'redirect' => '/editor', 'message' => "Welcome back, {$user['username']}!"]);
            return;
        }

        Session::flash('success', "Welcome back, {$user['username']}!");
        $this->redirect('/editor');
    }

    // ─── Logout ────────────────────────────────────────────────

    public function logout(array $params = []): void
    {
        Session::destroy();
        // Start a new session for flash message
        Session::start();
        Session::flash('success', 'You have been logged out.');
        $this->redirect('/');
    }

    // ─── Forgot Password ──────────────────────────────────────

    public function forgotPasswordForm(array $params = []): void
    {
        $this->render('auth/forgot-password', ['_title' => 'Forgot Password — Camagru']);
    }

    public function forgotPassword(array $params = []): void
    {
        // Rate limit: 3 reset requests per 5 minutes
        RateLimiter::enforce('forgot_password', 3, 300);

        $email = $this->input('email');

        $v = new Validator($_POST);
        $v->required('email', 'Email')->email('email', 'Email');

        if ($v->fails()) {
            Session::flash('error', $v->firstError());
            $this->redirect('/forgot-password');
            return;
        }

        $user = $this->user->findByEmail($email);

        // Always show success to prevent email enumeration
        if ($user) {
            $token = $this->user->setResetToken((int)$user['id']);
            Mailer::sendPasswordReset($email, $user['username'], $token);
        }

        Session::flash('success', 'If an account with that email exists, a password reset link has been sent.');
        $this->redirect('/login');
    }

    // ─── Reset Password ───────────────────────────────────────

    public function resetPasswordForm(array $params = []): void
    {
        $token = $this->query('token');

        if (empty($token)) {
            Session::flash('error', 'Invalid reset link.');
            $this->redirect('/login');
            return;
        }

        $user = $this->user->findByResetToken($token);
        if (!$user) {
            Session::flash('error', 'This reset link has expired. Please request a new one.');
            $this->redirect('/forgot-password');
            return;
        }

        $this->render('auth/reset-password', [
            '_title' => 'Reset Password — Camagru',
            'token'  => $token,
        ]);
    }

    public function resetPassword(array $params = []): void
    {
        $token    = $this->input('token');
        $password = $this->input('password');
        $confirm  = $this->input('password_confirm');

        $v = new Validator($_POST);
        $v->required('password', 'Password')
          ->passwordStrength('password', 'Password')
          ->required('password_confirm', 'Password confirmation')
          ->matches('password_confirm', 'password', 'Password confirmation');

        if ($v->fails()) {
            Session::flash('error', $v->firstError());
            $this->redirect("/reset-password?token={$token}");
            return;
        }

        $user = $this->user->findByResetToken($token);
        if (!$user) {
            Session::flash('error', 'This reset link has expired.');
            $this->redirect('/forgot-password');
            return;
        }

        $this->user->updatePassword((int)$user['id'], $password);
        Session::flash('success', 'Password updated successfully! You can now log in.');
        $this->redirect('/login');
    }
}
