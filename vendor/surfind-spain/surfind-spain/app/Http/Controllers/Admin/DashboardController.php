<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\Beach;
use App\Models\Comment;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\View\View;

class DashboardController extends Controller
{
    public function index(): View
    {
        $now = CarbonImmutable::now();
        $startOfMonth = $now->startOfMonth();
        $endOfMonth = $now->endOfMonth();

        return view('dashboard', [
            'metrics' => [
                [
                    'label' => 'Usuarios registrados',
                    'value' => User::withTrashed()->count(),
                    'description' => 'Cuentas creadas en total',
                    'icon' => 'users',
                ],
                [
                    'label' => 'Usuarios este mes',
                    'value' => User::withTrashed()
                        ->whereBetween('created_at', [$startOfMonth, $endOfMonth])
                        ->count(),
                    'description' => 'Altas del mes actual',
                    'icon' => 'user-plus',
                ],
                [
                    'label' => 'Playas creadas',
                    'value' => Beach::count(),
                    'description' => 'Playas creadas en total',
                    'icon' => 'map',
                ],
                [
                    'label' => 'Comentarios',
                    'value' => Comment::count(),
                    'description' => 'Actividad total',
                    'icon' => 'chat',
                ],
                [
                    'label' => 'Comentarios este mes',
                    'value' => Comment::whereBetween('created_at', [$startOfMonth, $endOfMonth])->count(),
                    'description' => 'Actividad de comunidad reciente',
                    'icon' => 'spark',
                ],
            ],
            'chart' => [
                'year' => $now->year,
                'labels' => ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'],
                'users' => $this->monthlyUserRegistrations($now),
                'comments' => $this->monthlyPublishedComments($now),
            ],
            'generatedAt' => $now,
        ]);
    }

    private function monthlyUserRegistrations(CarbonImmutable $date): array
    {
        return collect(range(1, 12))
            ->map(function (int $month) use ($date): int {
                $monthDate = $date->setDate($date->year, $month, 1);

                return User::withTrashed()
                    ->whereBetween('created_at', [$monthDate->startOfMonth(), $monthDate->endOfMonth()])
                    ->count();
            })
            ->all();
    }

    private function monthlyPublishedComments(CarbonImmutable $date): array
    {
        return collect(range(1, 12))
            ->map(function (int $month) use ($date): int {
                $monthDate = $date->setDate($date->year, $month, 1);

                return Comment::where('published', true)
                    ->whereBetween('created_at', [$monthDate->startOfMonth(), $monthDate->endOfMonth()])
                    ->count();
            })
            ->all();
    }
}
