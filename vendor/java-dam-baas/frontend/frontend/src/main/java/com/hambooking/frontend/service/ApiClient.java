package com.hambooking.frontend.service;

import com.fasterxml.jackson.databind.JavaType;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;

public final class ApiClient {
    private static final String BASE_URL = "http://localhost:8080/api";
    private final HttpClient httpClient;
    private final ObjectMapper mapper;

    private ApiClient() {
        this.httpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
        this.mapper = new ObjectMapper().registerModule(new JavaTimeModule())
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    }

    private static class Holder { private static final ApiClient INSTANCE = new ApiClient(); }
    public static ApiClient getInstance() { return Holder.INSTANCE; }

    // --- Métodos Públicos (Interfaz de Red) ---

    public <T> T get(String path, Class<T> type) throws ApiException {
        return call(build(path).GET().build(), type);
    }

    public <T> List<T> getList(String path, Class<T> type) throws ApiException {
        JavaType listType = mapper.getTypeFactory().constructCollectionType(List.class, type);
        return call(build(path).GET().build(), listType);
    }

    public <T> T post(String path, Object body, Class<T> type) throws ApiException {
        return call(build(path).header("Content-Type", "application/json")
                .POST(body(body)).build(), type);
    }

    public void put(String path, Object body) throws ApiException {
        call(build(path).header("Content-Type", "application/json")
                .PUT(body(body)).build(), Void.class);
    }

    public void patch(String path) throws ApiException {
        call(build(path).method("PATCH", HttpRequest.BodyPublishers.noBody()).build(), Void.class);
    }

    // --- El "Embudo" (Lógica Centralizada) ---

    private HttpRequest.Builder build(String path) {
        return HttpRequest.newBuilder().uri(URI.create(BASE_URL + path))
                .header("Accept", "application/json").timeout(Duration.ofSeconds(10));
    }

    private HttpRequest.BodyPublisher body(Object obj) throws ApiException {
        try { return HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(obj)); }
        catch (IOException e) { throw new ApiException("Error de serialización", 0); }
    }

    private <T> T call(HttpRequest request, Object type) throws ApiException {
        try {
            HttpResponse<String> resp = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            if (resp.statusCode() >= 300) throw new ApiException(extractError(resp.body(), resp.statusCode()), resp.statusCode());
            if (type == Void.class || resp.body().isEmpty()) return null;

            return (type instanceof Class)
                    ? mapper.readValue(resp.body(), (Class<T>) type)
                    : mapper.readValue(resp.body(), (JavaType) type);
        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException("El servidor no responde.", 0);
        }
    }

    private String extractError(String body, int code) {
        try {
            var node = mapper.readTree(body);
            if (node.has("message")) return node.get("message").asText();
        } catch (Exception ignored) {}
        return switch (code) {
            case 401 -> "Sesión expirada.";
            case 404 -> "No encontrado.";
            case 409 -> "Conflicto en los datos.";
            default -> "Error inesperado (" + code + ")";
        };
    }
}