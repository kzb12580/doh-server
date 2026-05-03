package scheduler

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"sub-store/models"
	"sub-store/parser"
)

// Scheduler handles automatic subscription refreshing in the background.
type Scheduler struct {
	store  *models.Store
	logger *log.Logger
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// New creates a new scheduler.
func New(store *models.Store, logger *log.Logger) *Scheduler {
	ctx, cancel := context.WithCancel(context.Background())
	return &Scheduler{
		store:  store,
		logger: logger,
		ctx:    ctx,
		cancel: cancel,
	}
}

// Start begins the background refresh loop.
func (s *Scheduler) Start() {
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		s.logger.Println("[scheduler] started")
		for {
			select {
			case <-s.ctx.Done():
				s.logger.Println("[scheduler] stopped")
				return
			case <-ticker.C:
				s.checkAndRefresh()
			}
		}
	}()
}

// Stop stops the scheduler and waits for it to finish.
func (s *Scheduler) Stop() {
	s.cancel()
	s.wg.Wait()
}

func (s *Scheduler) checkAndRefresh() {
	subs, err := s.store.ListSubscriptions()
	if err != nil {
		s.logger.Printf("[scheduler] list subs error: %v", err)
		return
	}
	now := time.Now()
	for _, sub := range subs {
		if !sub.AutoRefresh || sub.Interval <= 0 {
			continue
		}
		elapsed := now.Sub(sub.UpdatedAt)
		if elapsed < time.Duration(sub.Interval)*time.Minute {
			continue
		}
		s.logger.Printf("[scheduler] auto-refreshing: %s (%s)", sub.Name, sub.ID[:8])
		count, err := s.RefreshSub(sub.ID)
		if err != nil {
			s.logger.Printf("[scheduler] refresh %s failed: %v", sub.Name, err)
		} else {
			s.logger.Printf("[scheduler] refreshed %s: %d nodes", sub.Name, count)
		}
	}
}

// RefreshAll refreshes all subscriptions.
func (s *Scheduler) RefreshAll() error {
	subs, err := s.store.ListSubscriptions()
	if err != nil {
		return err
	}
	var errs []string
	for _, sub := range subs {
		_, err := s.RefreshSub(sub.ID)
		if err != nil {
			errs = append(errs, sub.Name+": "+err.Error())
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("some refreshes failed: %s", strings.Join(errs, "; "))
	}
	return nil
}

// RefreshSub refreshes a single subscription, returning node count.
func (s *Scheduler) RefreshSub(subID string) (int, error) {
	sub, err := s.store.GetSubscription(subID)
	if err != nil {
		return 0, fmt.Errorf("subscription not found: %w", err)
	}

	nodes, err := parser.FetchAndParse(sub.URL)
	if err != nil {
		return 0, fmt.Errorf("fetch failed: %w", err)
	}

	// Dedup nodes
	nodes = dedupNodes(nodes)

	for i := range nodes {
		nodes[i].SubID = subID
	}

	if err := s.store.SaveNodesForSub(subID, nodes); err != nil {
		return 0, err
	}

	sub.NodeCount = len(nodes)
	sub.UpdatedAt = time.Now()
	_ = s.store.SaveSubscription(sub)

	return len(nodes), nil
}

// dedupNodes removes duplicate nodes by type+server+port+credential key.
func dedupNodes(nodes []models.Node) []models.Node {
	seen := make(map[string]bool)
	var result []models.Node
	for _, n := range nodes {
		key := n.Type + "|" + n.Server + "|" + fmt.Sprintf("%d", n.Port)
		if n.UUID != "" {
			key += "|" + n.UUID
		} else if n.Password != "" {
			key += "|" + n.Password
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		result = append(result, n)
	}
	return result
}
