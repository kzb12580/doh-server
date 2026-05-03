FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /sub-store .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /sub-store .
COPY frontend/ frontend/
RUN mkdir -p /app/data
EXPOSE 8888
CMD ["./sub-store", "-port", "8888", "-config", "/app/data/config.json"]
