package org.example.takecareofmyfridgebe.domain.order.service;

import java.time.LocalDateTime;
import java.util.List;
import lombok.RequiredArgsConstructor;
import org.example.takecareofmyfridgebe.domain.order.entity.OrderOutboxEvent;
import org.example.takecareofmyfridgebe.domain.order.entity.OutboxStatus;
import org.example.takecareofmyfridgebe.domain.order.repository.OrderOutboxEventRepository;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

// 발행 스케줄러가 쓰는 outbox 조회·상태 변경. 건마다 트랜잭션이 따로 열려 한 건의 결과가 다른 건에 영향을 주지 않는다.
// 저장은 구매 확정 트랜잭션 안에서 OrderStatusService가 한다.
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class OrderOutboxService {

    private final OrderOutboxEventRepository orderOutboxEventRepository;

    public List<OrderOutboxEvent> findPending(int limit) {
        return orderOutboxEventRepository.findByStatusOrderByIdAsc(OutboxStatus.PENDING, PageRequest.of(0, limit));
    }

    @Transactional
    public void markPublished(Long id, LocalDateTime publishedAt) {
        find(id).markPublished(publishedAt);
    }

    // 바뀐 뒤 상태를 돌려준다. 실패 상태가 되었는지 스케줄러가 보고 로그를 남긴다
    @Transactional
    public OutboxStatus recordFailure(Long id, int maxAttempts) {
        OrderOutboxEvent outbox = find(id);
        outbox.recordFailure(maxAttempts);
        return outbox.getStatus();
    }

    private OrderOutboxEvent find(Long id) {
        return orderOutboxEventRepository.findById(id)
                .orElseThrow(() -> new IllegalStateException("outbox 이벤트가 없습니다: id=" + id));
    }
}
