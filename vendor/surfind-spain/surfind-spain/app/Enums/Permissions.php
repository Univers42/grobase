<?php

namespace App\Enums;

enum Permissions: string
{
    case VIEW_BEACHES = 'view beaches';
    case CREATE_BEACHES = 'create beaches';
    case EDIT_BEACHES = 'edit beaches';
    case DELETE_BEACHES = 'delete beaches';
    case CREATE_REVIEWS = 'create reviews';
    case EDIT_OWN_REVIEWS= 'edit own reviews';
    case DELETE_OWN_REVIEWS= 'delete own reviews';
    case DELETE_ANY_REVIEW = 'delete any review';
    case MANAGE_USERS = 'manage users';

}
