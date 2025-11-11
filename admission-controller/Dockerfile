FROM golang:1.22 as build
WORKDIR /src
COPY go.mod .
RUN go mod download
COPY cmd/server ./cmd/server
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/admission-webhook ./cmd/server

FROM gcr.io/distroless/static:nonroot
WORKDIR /
USER nonroot:nonroot
COPY --from=build /out/admission-webhook /admission-webhook
EXPOSE 8443
ENTRYPOINT ["/admission-webhook"]
