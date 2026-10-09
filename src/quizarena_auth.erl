-module(quizarena_auth).

-export([register/2, authenticate/2]).

-define(PBKDF2_ITERATIONS, 600000).
-define(SALT_BYTES, 16).
-define(HASH_BYTES, 32).
-define(DUMMY_SALT, <<0:128>>).
-define(MIN_USERNAME_LENGTH, 3).
-define(MAX_USERNAME_LENGTH, 30).
-define(MIN_PASSWORD_LENGTH, 8).
-define(MAX_PASSWORD_LENGTH, 128).

%% Valida i dati e registra un nuovo utente con una password derivata in modo sicuro.
register(Username0, Password) when is_list(Username0), is_list(Password) ->
    Username = string:trim(Username0),
    case validate_registration(Username, Password) of
        ok ->
            Salt = crypto:strong_rand_bytes(?SALT_BYTES),
            Hash = derive_password(Password, Salt, ?PBKDF2_ITERATIONS),
            Credentials = #{
                algorithm => pbkdf2_sha256,
                salt => Salt,
                iterations => ?PBKDF2_ITERATIONS,
                hash => Hash
            },
            case quizarena_db:create_user(Username, Credentials) of
                ok -> {ok, registered};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
register(_Username, _Password) ->
    {error, invalid_request}.

%% Verifica una password senza rivelare se lo username esiste.
authenticate(Username0, Password)
  when is_list(Username0), is_list(Password) ->
    Username = string:trim(Username0),
    case valid_username(Username) andalso valid_password(Password) of
        false ->
            {error, invalid_credentials};
        true ->
            authenticate_valid_input(Username, Password)
    end;
authenticate(_Username, _Password) ->
    {error, invalid_credentials}.

authenticate_valid_input(Username, Password) ->
    case quizarena_db:get_user(Username) of
        {ok, #{algorithm := pbkdf2_sha256,
               salt := Salt,
               iterations := Iterations,
               hash := ExpectedHash}}
          when is_binary(Salt), is_integer(Iterations),
               Iterations > 0, is_binary(ExpectedHash) ->
            ActualHash = derive_password(Password, Salt, Iterations),
            case crypto:hash_equals(ActualHash, ExpectedHash) of
                true -> {ok, Username};
                false -> {error, invalid_credentials}
            end;
        {ok, _MalformedCredentials} ->
            {error, invalid_credentials};
        {error, not_found} ->
            _ = derive_password(
                Password, ?DUMMY_SALT, ?PBKDF2_ITERATIONS),
            {error, invalid_credentials};
        {error, Reason} ->
            {error, Reason}
    end.

validate_registration(Username, Password) ->
    case valid_username(Username) of
        false -> {error, invalid_username};
        true ->
            case valid_password(Password) of
                true -> ok;
                false -> {error, invalid_password}
            end
    end.

valid_username(Username) ->
    Length = length(Username),
    Length >= ?MIN_USERNAME_LENGTH
        andalso Length =< ?MAX_USERNAME_LENGTH
        andalso lists:all(fun valid_username_character/1, Username).

valid_username_character(Character) ->
    (Character >= $a andalso Character =< $z)
        orelse (Character >= $A andalso Character =< $Z)
        orelse (Character >= $0 andalso Character =< $9)
        orelse Character =:= $_.

valid_password(Password) ->
    Length = length(Password),
    Length >= ?MIN_PASSWORD_LENGTH andalso Length =< ?MAX_PASSWORD_LENGTH.

derive_password(Password, Salt, Iterations) ->
    PasswordBinary = unicode:characters_to_binary(Password),
    crypto:pbkdf2_hmac(
        sha256, PasswordBinary, Salt, Iterations, ?HASH_BYTES).
