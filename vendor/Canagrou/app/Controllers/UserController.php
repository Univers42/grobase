<?php

declare(strict_types=1);

namespace App\Controllers;

use App\Core\Controller;
use App\Core\Session;
use App\Core\Validator;
use App\Core\Mailer;
use App\Models\User;

class UserController extends Controller
{
    private User $user;

    public function __construct()
    {
        $this->user = new User();
    }

    /**
     * Display settings page.
     */
    public function settings(array $params = []): void
    {
        $this->requireAuth();

        $userData = $this->user->findById($this->userId());

        $this->render('user/settings', [
            '_title' => 'Settings — Camagru',
            'user'   => $userData,
        ]);
    }

    /**
     * Update username.
     */
    public function updateUsername(array $params = []): void
    {
        $this->requireAuth();

        $username = $this->input('username');

        $data = array_merge($_POST, $this->jsonBody());
        $v = new Validator($data);
        $v->required('username', 'Username')
          ->minLength('username', 3, 'Username')
          ->maxLength('username', 20, 'Username')
          ->alphanumeric('username', 'Username');

        if ($v->fails()) {
            if ($this->wantsJson()) { $this->json(['error' => $v->firstError()], 422); return; }
            Session::flash('error', $v->firstError());
            $this->redirect('/settings');
            return;
        }

        // Check uniqueness (exclude self)
        $existing = $this->user->findByUsername($username);
        if ($existing && (int)$existing['id'] !== $this->userId()) {
            if ($this->wantsJson()) { $this->json(['error' => 'This username is already taken.'], 409); return; }
            Session::flash('error', 'This username is already taken.');
            $this->redirect('/settings');
            return;
        }

        $this->user->updateUsername($this->userId(), $username);
        Session::set('username', $username);

        if ($this->wantsJson()) { $this->json(['success' => true, 'message' => 'Username updated.']); return; }
        Session::flash('success', 'Username updated successfully.');
        $this->redirect('/settings');
    }

    /**
     * Update email (triggers re-verification).
     */
    public function updateEmail(array $params = []): void
    {
        $this->requireAuth();

        $email = $this->input('email');

        $v = new Validator($_POST);
        $v->required('email', 'Email')->email('email', 'Email');

        if ($v->fails()) {
            Session::flash('error', $v->firstError());
            $this->redirect('/settings');
            return;
        }

        // Check uniqueness (exclude self)
        $existing = $this->user->findByEmail($email);
        if ($existing && (int)$existing['id'] !== $this->userId()) {
            Session::flash('error', 'This email is already in use.');
            $this->redirect('/settings');
            return;
        }

        $result = $this->user->updateEmail($this->userId(), $email);
        $user = $this->user->findById($this->userId());

        // Send re-verification email
        Mailer::sendVerification($email, $user['username'], $result['token']);

        Session::flash('success', 'Email updated. Please check your inbox to re-verify.');
        $this->redirect('/settings');
    }

    /**
     * Update password.
     */
    public function updatePassword(array $params = []): void
    {
        $this->requireAuth();

        $current  = $this->input('current_password');
        $password = $this->input('password');
        $confirm  = $this->input('password_confirm');

        $data = array_merge($_POST, $this->jsonBody());
        $v = new Validator($data);
        $v->required('current_password', 'Current password')
          ->required('password', 'New password')
          ->passwordStrength('password', 'New password')
          ->required('password_confirm', 'Password confirmation')
          ->matches('password_confirm', 'password', 'Password confirmation');

        if ($v->fails()) {
            if ($this->wantsJson()) { $this->json(['error' => $v->firstError()], 422); return; }
            Session::flash('error', $v->firstError());
            $this->redirect('/settings');
            return;
        }

        $user = $this->user->findById($this->userId());

        if (!password_verify($current, $user['password'])) {
            if ($this->wantsJson()) { $this->json(['error' => 'Current password is incorrect.'], 403); return; }
            Session::flash('error', 'Current password is incorrect.');
            $this->redirect('/settings');
            return;
        }

        $this->user->updatePassword($this->userId(), $password);
        if ($this->wantsJson()) { $this->json(['success' => true, 'message' => 'Password updated.']); return; }
        Session::flash('success', 'Password updated successfully.');
        $this->redirect('/settings');
    }

    /**
     * Toggle comment notifications.
     */
    public function updateNotifications(array $params = []): void
    {
        $this->requireAuth();

        $notify = isset($_POST['notify_comments']);
        $this->user->updateNotifyComments($this->userId(), $notify);

        if ($this->wantsJson()) {
            $this->json(['success' => true, 'notify' => $notify]);
            return;
        }

        Session::flash('success', 'Notification preferences updated.');
        $this->redirect('/settings');
    }
}
