<?php

namespace App\Http\Controllers\Admin;

use App\Concerns\PasswordValidationRules;
use App\Concerns\ProfileValidationRules;
use App\Enums\Roles;
use App\Http\Controllers\Controller;
use App\Models\User;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Validation\Rules\Enum;
use Illuminate\View\View;

class UserController extends Controller
{
    use PasswordValidationRules, ProfileValidationRules;

    public function index(Request $request): View
    {
        $filters = $request->validate([
            'search' => ['nullable', 'string', 'max:255'],
            'status' => ['nullable', 'in:all,active,disabled'],
        ]);

        $search = $filters['search'] ?? null;
        $status = $filters['status'] ?? 'all';

        $users = User::query()
            ->withTrashed()
            ->with('roles')
            ->when($search, function ($query, string $search) {
                $query->where(function ($query) use ($search) {
                    $query
                        ->where('name', 'like', "%{$search}%")
                        ->orWhere('email', 'like', "%{$search}%");
                });
            })
            ->when($status === 'active', fn ($query) => $query->whereNull('deleted_at'))
            ->when($status === 'disabled', fn ($query) => $query->onlyTrashed())
            ->latest()
            ->paginate(10)
            ->withQueryString();

        return view('admin.users.index', compact('users', 'search', 'status'));
    }

    public function create(): View
    {
        return view('admin.users.create', [
            'roles' => Roles::cases(),
        ]);
    }

    public function store(Request $request): RedirectResponse
    {
        $validated = $request->validate([
            ...$this->profileRules(),
            'password' => $this->passwordRules(),
            'role' => ['required', new Enum(Roles::class)],
        ]);

        $user = User::create([
            'name' => $validated['name'],
            'email' => $validated['email'],
            'password' => $validated['password'],
            'email_verified_at' => now(),
        ]);

        $user->syncRoles([$validated['role']]);

        return redirect()
            ->route('admin.users.show', $user)
            ->with('status', 'El usuario ha sido creado correctamente.');
    }

    public function show(User $user): View
    {
        $user->load('roles')
            ->loadCount(['comments', 'createdBeaches', 'favoriteBeaches']);

        $comments = $user->comments()
            ->with('beach')
            ->latest()
            ->paginate(8, ['*'], 'comments_page');

        return view('admin.users.show', compact('user', 'comments'));
    }

    public function edit(User $user): View
    {
        $user->load('roles');

        return view('admin.users.edit', [
            'user' => $user,
            'roles' => Roles::cases(),
        ]);
    }

    public function update(Request $request, User $user): RedirectResponse
    {
        $validated = $request->validate([
            ...$this->profileRules($user->id),
            'role' => ['required', new Enum(Roles::class)],
            'password' => ['nullable', 'string', 'min:6', 'confirmed'],
        ]);

        $user->fill([
            'name' => $validated['name'],
            'email' => $validated['email'],
        ]);

        if ($user->isDirty('email')) {
            $user->email_verified_at = null;
        }

        if ($validated['password'] ?? false) {
            $user->password = $validated['password'];
        }

        $user->save();
        $user->syncRoles([$validated['role']]);

        return redirect()
            ->route('admin.users.show', $user)
            ->with('status', 'El usuario ha sido actualizado correctamente.');
    }

    public function destroy(User $user): RedirectResponse
    {
        if ($user->is(auth()->user())) {
            return redirect()
                ->route('admin.users.index')
                ->with('error', 'No puedes deshabilitar tu propia cuenta.');
        }

        $user->delete();

        return redirect()
            ->route('admin.users.index')
            ->with('status', 'La cuenta de usuario ha sido deshabilitada.');
    }

    public function restore(int $user): RedirectResponse
    {
        $user = User::withTrashed()->findOrFail($user);

        $user->restore();

        return redirect()
            ->route('admin.users.index')
            ->with('status', 'La cuenta de usuario ha sido reactivada.');
    }
}
