# Multi-stage build for github-mcp-server backend
FROM golang:1.24-alpine AS builder

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY internal/ ./internal/
COPY backend/ ./backend/

# Build the backend
WORKDIR /app/backend
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o backend main.go

# Runtime stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /root/

# Copy the binary from builder
COPY --from=builder /app/backend/backend .

# Create directory for demo UI
RUN mkdir -p /usr/share/nginx/html

# Expose port
EXPOSE 8187

# Run the backend
CMD ["./backend"]