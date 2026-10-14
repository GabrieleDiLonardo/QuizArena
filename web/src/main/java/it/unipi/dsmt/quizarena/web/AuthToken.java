package it.unipi.dsmt.quizarena.web;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.List;
import java.util.logging.Logger;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServletRequest;

// Credenziale di login verificabile da qualunque Tomcat del cluster.
// La HttpSession vive in un solo Tomcat: se l'utente viene servito da un
// altro (bilanciamento o caduta del primo), il cookie firmato permette di
// riconoscerlo senza un nuovo login. Il token contiene username, scadenza e
// un identificativo casuale (jti), firmati con HMAC-SHA256 tramite un
// segreto condiviso fra tutti i Tomcat. Il jti permette di revocare il
// singolo login al logout (vedi TokenRevocations).
public final class AuthToken {

    public static final String COOKIE_NAME = "QA_AUTH";
    private static final Duration VALIDITY = Duration.ofHours(12);
    private static final String ALGORITHM = "HmacSHA256";
    private static final Logger LOGGER =
            Logger.getLogger(AuthToken.class.getName());
    private static final Base64.Encoder ENCODER =
            Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder DECODER = Base64.getUrlDecoder();
    private static final SecureRandom RANDOM = new SecureRandom();

    private static volatile byte[] secret;

    // Contenuto di un token valido.
    public record Verified(String username, String jti, long expiresAtMillis) {
    }

    // Token appena emesso, da inviare come cookie.
    public record Issued(String value, Verified claims) {
    }

    private AuthToken() {
    }

    // Il segreto arriva da QUIZARENA_AUTH_SECRET. Senza segreto ne viene
    // generato uno casuale: va bene con un solo Tomcat, ma in quel caso i
    // cookie non sono riconosciuti dagli altri nodi.
    public static void configure(String configuredSecret) {
        if (configuredSecret == null || configuredSecret.isBlank()) {
            byte[] random = new byte[32];
            RANDOM.nextBytes(random);
            secret = random;
            LOGGER.warning("QUIZARENA_AUTH_SECRET not set: login cookies "
                    + "are valid only on this Tomcat");
        } else {
            secret = configuredSecret.getBytes(StandardCharsets.UTF_8);
        }
    }

    public static Issued issue(String username) {
        long expiresAt = Instant.now().plus(VALIDITY).getEpochSecond();
        byte[] id = new byte[16];
        RANDOM.nextBytes(id);
        String jti = ENCODER.encodeToString(id);
        String payload = ENCODER.encodeToString(
                username.getBytes(StandardCharsets.UTF_8))
                + "." + expiresAt + "." + jti;
        return new Issued(payload + "." + sign(payload),
                new Verified(username, jti, expiresAt * 1000));
    }

    // Restituisce il contenuto del token se e' integro, non scaduto e non
    // revocato da un logout.
    public static Verified verify(String token) {
        if (token == null) {
            return null;
        }
        String[] parts = token.split("\\.");
        if (parts.length != 4) {
            return null;
        }
        String payload = parts[0] + "." + parts[1] + "." + parts[2];
        byte[] expected = sign(payload).getBytes(StandardCharsets.US_ASCII);
        byte[] actual = parts[3].getBytes(StandardCharsets.US_ASCII);
        if (!MessageDigest.isEqual(expected, actual)) {
            return null;
        }
        try {
            long expiresAt = Long.parseLong(parts[1]);
            if (expiresAt < Instant.now().getEpochSecond()
                    || TokenRevocations.isRevoked(parts[2])) {
                return null;
            }
            String username = new String(
                    DECODER.decode(parts[0]), StandardCharsets.UTF_8);
            return username.isBlank()
                    ? null
                    : new Verified(username, parts[2], expiresAt * 1000);
        } catch (IllegalArgumentException exception) {
            return null;
        }
    }

    public static Verified from(HttpServletRequest request) {
        Cookie[] cookies = request.getCookies();
        if (cookies == null) {
            return null;
        }
        for (Cookie cookie : cookies) {
            if (COOKIE_NAME.equals(cookie.getName())) {
                return verify(cookie.getValue());
            }
        }
        return null;
    }

    // Variante per l'handshake WebSocket, che espone solo gli header grezzi.
    public static Verified fromCookieHeaders(List<String> headers) {
        if (headers == null) {
            return null;
        }
        for (String header : headers) {
            for (String pair : header.split(";")) {
                String[] nameValue = pair.trim().split("=", 2);
                if (nameValue.length == 2
                        && COOKIE_NAME.equals(nameValue[0])) {
                    return verify(nameValue[1]);
                }
            }
        }
        return null;
    }

    public static Cookie cookie(String token, String contextPath) {
        Cookie cookie = new Cookie(COOKIE_NAME, token);
        cookie.setHttpOnly(true);
        cookie.setPath(contextPath.isEmpty() ? "/" : contextPath);
        cookie.setMaxAge((int) VALIDITY.toSeconds());
        cookie.setAttribute("SameSite", "Lax");
        return cookie;
    }

    public static Cookie expiredCookie(String contextPath) {
        Cookie cookie = cookie("", contextPath);
        cookie.setMaxAge(0);
        return cookie;
    }

    private static String sign(String payload) {
        byte[] key = secret;
        if (key == null) {
            throw new IllegalStateException("AuthToken not configured");
        }
        try {
            Mac mac = Mac.getInstance(ALGORITHM);
            mac.init(new SecretKeySpec(key, ALGORITHM));
            return ENCODER.encodeToString(
                    mac.doFinal(payload.getBytes(StandardCharsets.UTF_8)));
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("HMAC unavailable", exception);
        }
    }
}
