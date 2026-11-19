package org.example.takecareofmyfridgebe.domain.order.entity;

// outbox 이벤트 발행 상태. FAILED는 시도 상한을 넘겨 더 보내지 않고 따로 확인할 건이다.
public enum OutboxStatus {
    PENDING,
    PUBLISHED,
    FAILED
}
