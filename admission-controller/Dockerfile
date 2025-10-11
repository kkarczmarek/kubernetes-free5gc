# Build stage
FROM golang:1.22 AS builder
WORKDIR /src
# najpierw moduły (lepszy cache)
COPY go.mod ./
RUN go mod download
# teraz reszta źródeł
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/server ./cmd/server

# Run stage
FROM gcr.io/distroless/static:nonroot
USER nonroot:nonroot
WORKDIR /
COPY --from=builder /out/server /server
EXPOSE 8443
ENTRYPOINT ["/server"]
