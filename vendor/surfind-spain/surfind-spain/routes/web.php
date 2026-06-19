<?php

use App\Http\Controllers\Admin\BeachController as AdminBeachController;
use App\Http\Controllers\Admin\CommentController as AdminCommentController;
use App\Http\Controllers\Admin\DashboardController as AdminDashboardController;
use App\Http\Controllers\Admin\UserController as AdminUserController;
use App\Http\Controllers\BeachController;
use App\Http\Controllers\CommentController;
use App\Http\Controllers\CommunityController;
use App\Http\Controllers\FavoriteController;
use App\Http\Controllers\HomeController;
use Illuminate\Support\Facades\Route;

Route::get('/', [HomeController::class, 'index'])->name('home');
Route::get('playas', [BeachController::class, 'index'])->name('beaches.index');
Route::get('playas/{beach:slug}', [BeachController::class, 'show'])->name('beaches.show');
Route::get('mapa', [BeachController::class, 'map'])->name('map');
Route::get('comunidad', [CommunityController::class, 'index'])->name('community.index');

Route::middleware(['auth', 'verified'])->group(function () {
    Route::post('playas/{beach:slug}/guardar', [FavoriteController::class, 'store'])->name('beaches.favorites.store');
    Route::delete('playas/{beach:slug}/guardar', [FavoriteController::class, 'destroy'])->name('beaches.favorites.destroy');
    Route::post('playas/{beach:slug}/comentarios', [CommentController::class, 'store'])->name('beaches.comments.store');

    Route::get('dashboard', [AdminDashboardController::class, 'index'])->name('dashboard')->middleware('role:admin');

    Route::prefix('admin')->as('admin.')->middleware('role:admin')->group(function () {
        Route::group(['prefix' => 'playas', 'as' => 'beaches.', 'controller' => AdminBeachController::class], function () {
            Route::get('/', 'index')->name('index')->middleware('permission:view beaches');
            Route::get('/create', 'create')->name('create')->middleware('permission:create beaches');
            Route::post('/store', 'store')->name('store')->middleware('permission:create beaches');
            Route::get('/{beach}', 'show')->name('show')->middleware('permission:view beaches');
            Route::get('/{beach}/edit', 'edit')->name('edit')->middleware('permission:edit beaches');
            Route::put('/{beach}/edit', 'update')->name('update')->middleware('permission:edit beaches');
            Route::delete('/{beach}/destroy', 'destroy')->name('destroy')->middleware('permission:delete beaches');
        });

        Route::group(['prefix' => 'usuarios', 'as' => 'users.', 'controller' => AdminUserController::class], function () {
            Route::get('/', 'index')->name('index')->middleware('permission:manage users');
            Route::get('/create', 'create')->name('create')->middleware('permission:manage users');
            Route::post('/store', 'store')->name('store')->middleware('permission:manage users');
            Route::get('/{user}', 'show')->name('show')->middleware('permission:manage users');
            Route::get('/{user}/edit', 'edit')->name('edit')->middleware('permission:manage users');
            Route::put('/{user}/edit', 'update')->name('update')->middleware('permission:manage users');
            Route::patch('/{user}/restore', 'restore')->name('restore')->middleware('permission:manage users');
            Route::delete('/{user}/destroy', 'destroy')->name('destroy')->middleware('permission:manage users');
        });

        Route::delete('comentarios/{comment}/destroy', [AdminCommentController::class, 'destroy'])
            ->name('comments.destroy')
            ->middleware('permission:delete any review');
    });
});

require __DIR__.'/settings.php';
