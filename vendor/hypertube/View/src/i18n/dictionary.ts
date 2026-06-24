export const LANGUAGES = ['en', 'fr', 'es'] as const;
export type Lang = (typeof LANGUAGES)[number];

export const LANGUAGE_LABELS: Record<Lang, string> = {
  en: 'English',
  fr: 'Français',
  es: 'Español',
};

export type MessageKey =
  | 'app.title'
  | 'nav.library'
  | 'nav.profile'
  | 'nav.logout'
  | 'nav.language'
  | 'auth.register'
  | 'auth.login'
  | 'auth.email'
  | 'auth.username'
  | 'auth.firstName'
  | 'auth.lastName'
  | 'auth.password'
  | 'auth.identifier'
  | 'auth.forgot'
  | 'auth.reset'
  | 'auth.resetSent'
  | 'auth.oauth42'
  | 'auth.oauthGoogle'
  | 'auth.haveAccount'
  | 'auth.noAccount'
  | 'library.search'
  | 'library.popular'
  | 'library.sort'
  | 'library.sortName'
  | 'library.sortGenre'
  | 'library.sortRating'
  | 'library.sortYear'
  | 'library.watched'
  | 'library.unwatched'
  | 'library.empty'
  | 'movie.summary'
  | 'movie.cast'
  | 'movie.director'
  | 'movie.producer'
  | 'movie.comments'
  | 'movie.postComment'
  | 'movie.commentPlaceholder'
  | 'movie.loading'
  | 'library.results'
  | 'library.clear'
  | 'library.classics'
  | 'library.silent'
  | 'library.scifiHorror'
  | 'library.comedy'
  | 'library.play'
  | 'library.details'
  | 'movie.related'
  | 'movie.showMore'
  | 'movie.showLess'
  | 'movie.noComments'
  | 'movie.back'
  | 'profile.title'
  | 'profile.edit'
  | 'profile.save'
  | 'profile.avatar'
  | 'common.submit'
  | 'common.error';

type Dict = Record<MessageKey, string>;

const en: Dict = {
  'app.title': 'Hypertube',
  'nav.library': 'Library',
  'nav.profile': 'Profile',
  'nav.logout': 'Log out',
  'nav.language': 'Language',
  'auth.register': 'Register',
  'auth.login': 'Log in',
  'auth.email': 'Email',
  'auth.username': 'Username',
  'auth.firstName': 'First name',
  'auth.lastName': 'Last name',
  'auth.password': 'Password',
  'auth.identifier': 'Email',
  'auth.forgot': 'Forgot password?',
  'auth.reset': 'Send reset link',
  'auth.resetSent': 'If that email exists, a reset link was sent.',
  'auth.oauth42': 'Continue with 42',
  'auth.oauthGoogle': 'Continue with Google',
  'auth.haveAccount': 'Already have an account? Log in',
  'auth.noAccount': "No account? Register",
  'library.search': 'Search films',
  'library.popular': 'Popular',
  'library.sort': 'Sort by',
  'library.sortName': 'Name',
  'library.sortGenre': 'Genre',
  'library.sortRating': 'Rating',
  'library.sortYear': 'Year',
  'library.watched': 'Watched',
  'library.unwatched': 'Not watched',
  'library.empty': 'No films found.',
  'library.results': 'Search results',
  'library.clear': 'Clear',
  'library.classics': 'Classics',
  'library.silent': 'Silent Era',
  'library.scifiHorror': 'Sci-Fi & Horror',
  'library.comedy': 'Comedy',
  'library.play': 'Play',
  'library.details': 'Details',
  'movie.related': 'More like this',
  'movie.showMore': 'Show more',
  'movie.showLess': 'Show less',
  'movie.noComments': 'No comments yet. Be the first.',
  'movie.back': 'Back',
  'movie.summary': 'Summary',
  'movie.cast': 'Cast',
  'movie.director': 'Director',
  'movie.producer': 'Producer',
  'movie.comments': 'Comments',
  'movie.postComment': 'Post',
  'movie.commentPlaceholder': 'Write a comment…',
  'movie.loading': 'Preparing stream…',
  'profile.title': 'Profile',
  'profile.edit': 'Edit',
  'profile.save': 'Save',
  'profile.avatar': 'Avatar URL',
  'common.submit': 'Submit',
  'common.error': 'Something went wrong.',
};

const fr: Dict = {
  ...en,
  'nav.library': 'Bibliothèque',
  'nav.profile': 'Profil',
  'nav.logout': 'Déconnexion',
  'nav.language': 'Langue',
  'auth.register': "S'inscrire",
  'auth.login': 'Connexion',
  'auth.email': 'E-mail',
  'auth.username': "Nom d'utilisateur",
  'auth.firstName': 'Prénom',
  'auth.lastName': 'Nom',
  'auth.password': 'Mot de passe',
  'auth.identifier': 'E-mail',
  'auth.forgot': 'Mot de passe oublié ?',
  'auth.reset': 'Envoyer le lien',
  'auth.resetSent': 'Si cet e-mail existe, un lien a été envoyé.',
  'auth.oauth42': 'Continuer avec 42',
  'auth.oauthGoogle': 'Continuer avec Google',
  'auth.haveAccount': 'Déjà un compte ? Connexion',
  'auth.noAccount': "Pas de compte ? S'inscrire",
  'library.search': 'Rechercher des films',
  'library.popular': 'Populaires',
  'library.sort': 'Trier par',
  'library.sortName': 'Nom',
  'library.sortGenre': 'Genre',
  'library.sortRating': 'Note',
  'library.sortYear': 'Année',
  'library.watched': 'Vu',
  'library.unwatched': 'Non vu',
  'library.empty': 'Aucun film trouvé.',
  'library.results': 'Résultats de recherche',
  'library.clear': 'Effacer',
  'library.classics': 'Classiques',
  'library.silent': 'Cinéma muet',
  'library.scifiHorror': 'SF & Horreur',
  'library.comedy': 'Comédie',
  'library.play': 'Lecture',
  'library.details': 'Détails',
  'movie.related': 'À voir aussi',
  'movie.showMore': 'Voir plus',
  'movie.showLess': 'Voir moins',
  'movie.noComments': 'Aucun commentaire. Soyez le premier.',
  'movie.back': 'Retour',
  'movie.comments': 'Commentaires',
  'movie.postComment': 'Publier',
  'movie.commentPlaceholder': 'Écrire un commentaire…',
  'movie.loading': 'Préparation du flux…',
  'profile.title': 'Profil',
  'profile.edit': 'Modifier',
  'profile.save': 'Enregistrer',
  'profile.avatar': "URL de l'avatar",
  'common.error': 'Une erreur est survenue.',
};

const es: Dict = {
  ...en,
  'nav.library': 'Biblioteca',
  'nav.profile': 'Perfil',
  'nav.logout': 'Cerrar sesión',
  'nav.language': 'Idioma',
  'auth.register': 'Registrarse',
  'auth.login': 'Entrar',
  'auth.password': 'Contraseña',
  'auth.forgot': '¿Olvidaste la contraseña?',
  'auth.reset': 'Enviar enlace',
  'auth.oauth42': 'Continuar con 42',
  'auth.oauthGoogle': 'Continuar con Google',
  'library.search': 'Buscar películas',
  'library.popular': 'Populares',
  'library.sort': 'Ordenar por',
  'library.watched': 'Visto',
  'library.unwatched': 'No visto',
  'library.empty': 'No se encontraron películas.',
  'library.results': 'Resultados de búsqueda',
  'library.clear': 'Limpiar',
  'library.classics': 'Clásicos',
  'library.silent': 'Cine mudo',
  'library.scifiHorror': 'Ciencia ficción y terror',
  'library.comedy': 'Comedia',
  'library.play': 'Reproducir',
  'library.details': 'Detalles',
  'movie.related': 'Más como esto',
  'movie.showMore': 'Ver más',
  'movie.showLess': 'Ver menos',
  'movie.noComments': 'Aún no hay comentarios. Sé el primero.',
  'movie.back': 'Volver',
  'movie.comments': 'Comentarios',
  'movie.postComment': 'Publicar',
  'profile.title': 'Perfil',
  'profile.save': 'Guardar',
  'common.error': 'Algo salió mal.',
};

export const DICTIONARIES: Record<Lang, Dict> = { en, fr, es };
