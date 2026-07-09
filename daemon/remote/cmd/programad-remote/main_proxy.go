package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"time"
)

// --- proxy.* RPC handlers: raw TCP stream tunneling over the daemon's
// stdio RPC connection (proxy.open/close/write/stream.subscribe). ---

func (s *rpcServer) handleProxyOpen(req rpcRequest) rpcResponse {
	host, ok := getStringParam(req.Params, "host")
	if !ok || host == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.open requires host",
			},
		}
	}
	port, ok := getIntParam(req.Params, "port")
	if !ok || port <= 0 || port > 65535 {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.open requires port in range 1-65535",
			},
		}
	}

	timeoutMs := 10000
	if parsed, hasTimeout := getIntParam(req.Params, "timeout_ms"); hasTimeout && parsed >= 0 {
		timeoutMs = parsed
	}

	conn, err := net.DialTimeout(
		"tcp",
		net.JoinHostPort(host, strconv.Itoa(port)),
		time.Duration(timeoutMs)*time.Millisecond,
	)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "open_failed",
				Message: err.Error(),
			},
		}
	}
	setTCPNoDelay(conn)

	s.mu.Lock()
	streamID := fmt.Sprintf("s-%d", s.nextStreamID)
	s.nextStreamID++
	s.streams[streamID] = &streamState{conn: conn}
	s.mu.Unlock()

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"stream_id": streamID,
		},
	}
}

func (s *rpcServer) handleProxyClose(req rpcRequest) rpcResponse {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.close requires stream_id",
			},
		}
	}

	s.mu.Lock()
	state, exists := s.streams[streamID]
	if exists {
		delete(s.streams, streamID)
	}
	s.mu.Unlock()

	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"closed": true,
			},
		}
	}

	_ = state.conn.Close()
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"closed": true,
		},
	}
}

func (s *rpcServer) handleProxyWrite(req rpcRequest) rpcResponse {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.write requires stream_id",
			},
		}
	}
	dataBase64, ok := getStringParam(req.Params, "data_base64")
	if !ok {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.write requires data_base64",
			},
		}
	}
	payload, err := base64.StdEncoding.DecodeString(dataBase64)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "data_base64 must be valid base64",
			},
		}
	}

	state, found := s.getStream(streamID)
	if !found {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "stream not found",
			},
		}
	}
	conn := state.conn

	timeoutMs := 8000
	if parsed, hasTimeout := getIntParam(req.Params, "timeout_ms"); hasTimeout {
		timeoutMs = parsed
	}
	if timeoutMs > 0 {
		if err := conn.SetWriteDeadline(time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)); err != nil {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "stream_error",
					Message: err.Error(),
				},
			}
		}
		defer conn.SetWriteDeadline(time.Time{})
	}

	total := 0
	for total < len(payload) {
		written, writeErr := conn.Write(payload[total:])
		if written == 0 && writeErr == nil {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "stream_error",
					Message: "write made no progress",
				},
			}
		}
		total += written
		if writeErr != nil {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "stream_error",
					Message: writeErr.Error(),
				},
			}
		}
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"written": total,
		},
	}
}

func (s *rpcServer) handleProxyStreamSubscribe(req rpcRequest) rpcResponse {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.stream.subscribe requires stream_id",
			},
		}
	}

	s.mu.Lock()
	state, found := s.streams[streamID]
	if !found {
		s.mu.Unlock()
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "stream not found",
			},
		}
	}
	alreadySubscribed := state.readerStarted
	if !alreadySubscribed {
		state.readerStarted = true
	}
	conn := state.conn
	s.mu.Unlock()

	if !alreadySubscribed {
		go s.streamPump(streamID, conn)
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"subscribed":         true,
			"already_subscribed": alreadySubscribed,
		},
	}
}

func (s *rpcServer) getStream(streamID string) (*streamState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.streams[streamID]
	return state, ok
}

func (s *rpcServer) dropStream(streamID string) {
	s.mu.Lock()
	state, ok := s.streams[streamID]
	if ok {
		delete(s.streams, streamID)
	}
	s.mu.Unlock()
	if ok {
		_ = state.conn.Close()
	}
}

func (s *rpcServer) streamPump(streamID string, conn net.Conn) {
	defer func() {
		if recovered := recover(); recovered != nil {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:    "proxy.stream.error",
				StreamID: streamID,
				Error:    fmt.Sprintf("stream panic: %v", recovered),
			})
			s.dropStream(streamID)
		}
	}()

	buffer := make([]byte, 32768)
	for {
		n, readErr := conn.Read(buffer)
		data := append([]byte(nil), buffer[:max(0, n)]...)
		if len(data) > 0 {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:      "proxy.stream.data",
				StreamID:   streamID,
				DataBase64: base64.StdEncoding.EncodeToString(data),
			})
		}

		if readErr == nil {
			if n == 0 {
				_ = s.frameWriter.writeEvent(rpcEvent{
					Event:    "proxy.stream.error",
					StreamID: streamID,
					Error:    "read made no progress",
				})
				s.dropStream(streamID)
				return
			}
			continue
		}

		if readErr == io.EOF {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:      "proxy.stream.eof",
				StreamID:   streamID,
				DataBase64: "",
			})
		} else if !errors.Is(readErr, net.ErrClosed) {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:    "proxy.stream.error",
				StreamID: streamID,
				Error:    readErr.Error(),
			})
		}

		s.dropStream(streamID)
		return
	}
}
