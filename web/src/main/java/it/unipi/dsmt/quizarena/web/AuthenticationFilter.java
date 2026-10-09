package it.unipi.dsmt.quizarena.web;

import java.io.IOException;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.annotation.WebFilter;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

@WebFilter(urlPatterns = {
    "/lobby.html",
    "/host.html",
    "/play.html",
    "/quizzes",
    "/api/*"
})
public final class AuthenticationFilter implements Filter {

    @Override
    public void doFilter(
            ServletRequest servletRequest,
            ServletResponse servletResponse,
            FilterChain chain
    ) throws IOException, ServletException {
        HttpServletRequest request = (HttpServletRequest) servletRequest;
        HttpServletResponse response = (HttpServletResponse) servletResponse;
        HttpSession session = request.getSession(false);

        if (AuthenticationSession.username(session) == null) {
            if (request.getServletPath().startsWith("/api/")) {
                response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
                response.setContentType("application/json");
                response.setCharacterEncoding("UTF-8");
                response.getWriter().write(
                        "{\"error\":\"Autenticazione richiesta\"}");
                return;
            }
            response.sendRedirect(response.encodeRedirectURL(
                    request.getContextPath() + "/login"));
            return;
        }

        response.setHeader("Cache-Control", "no-store");
        chain.doFilter(request, response);
    }
}
