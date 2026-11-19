package org.example.takecareofmyfridgebe.domain.order.repository;

import java.util.List;
import org.example.takecareofmyfridgebe.domain.order.entity.OrderOutboxEvent;
import org.example.takecareofmyfridgebe.domain.order.entity.OutboxStatus;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

public interface OrderOutboxEventRepository extends JpaRepository<OrderOutboxEvent, Long> {

    // 저장한 순서대로 보낸다. (status, id) 인덱스를 탄다.
    List<OrderOutboxEvent> findByStatusOrderByIdAsc(OutboxStatus status, Pageable pageable);
}
