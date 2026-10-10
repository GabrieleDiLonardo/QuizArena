package it.unipi.dsmt.quizarena.web;

import java.io.IOException;
import java.util.Map;

import com.fasterxml.jackson.databind.ObjectMapper;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

@WebServlet(name = "meServlet", value = "/api/me")
public final class MeServlet extends HttpServlet {

    private static final ObjectMapper JSON = new ObjectMapper();

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws IOException {
        HttpSession session = request.getSession(false);
        String username = AuthenticationSession.username(session);

        response.setContentType("application/json");
        response.setCharacterEncoding("UTF-8");
        response.setHeader("Cache-Control", "no-store");

        if (username == null) {
            JSON.writeValue(response.getWriter(),
                    Map.of("authenticated", false));
            return;
        }

        JSON.writeValue(response.getWriter(), Map.of(
                "authenticated", true,
                "username", username
        ));
    }
}