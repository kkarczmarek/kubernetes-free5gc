FROM golang:1.22 as build
WORKDIR /src

# Najpierw same moduły, żeby cache działał
COPY go.mod ./
RUN go mod download

# Potem kod serwera i "tidy", aby wygenerować/uzupełnić go.sum
COPY cmd/server ./cmd/server
RUN go mod tidy

# Build binarki
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/admission-webhook ./cmd/server

# Minimalny runtime
FROM gcr.io/distroless/static:nonroot
WORKDIR /
USER nonroot:nonroot
COPY --from=build /out/admission-webhook /admission-webhook
EXPOSE 8443
ENTRYPOINT ["/admission-webhook"]
