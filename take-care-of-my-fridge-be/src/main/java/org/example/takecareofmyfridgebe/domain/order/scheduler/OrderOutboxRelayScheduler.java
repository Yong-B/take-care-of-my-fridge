package org.example.takecareofmyfridgebe.domain.order.scheduler;

import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import net.javacrumbs.shedlock.spring.annotation.SchedulerLock;
import org.apache.kafka.common.errors.RetriableException;
import org.example.takecareofmyfridgebe.domain.order.entity.OrderOutboxEvent;
import org.example.takecareofmyfridgebe.domain.order.entity.OutboxStatus;
import org.example.takecareofmyfridgebe.domain.order.event.OrderConfirmedEvent;
import org.example.takecareofmyfridgebe.domain.order.event.OutboxPayloadMapper;
import org.example.takecareofmyfridgebe.domain.order.service.OrderOutboxService;
import org.example.takecareofmyfridgebe.global.config.scheduling.SchedulingConfig;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

// 대기 상태의 구매 확정 outbox를 오래된 순으로 Kafka에 보낸다. Kafka가 받았다고 응답한 건만 완료로 바꾼다.
// 실패는 두 가지로 나눈다.
// - Kafka에 닿지 못함(브로커 중단·시간 초과): 이벤트 탓이 아니므로 실패 횟수를 올리지 않는다. 이번 주기의 나머지도 보내지 않고 다음 주기에 다시 보낸다.
//   횟수를 올리면 Kafka가 오래 멈췄을 때 멀쩡한 이벤트가 실패 상태가 되어 영영 보내지지 않는다.
// - 이 이벤트만의 문제(저장된 내용을 읽지 못함, Kafka가 이 메시지를 거절함): 실패 횟수를 올리고 다음 건은 계속 보낸다. 상한에 닿으면 실패 상태로 남긴다.
// 완료 표시 전에 서버가 죽으면 같은 이벤트를 다시 보낼 수 있지만, 냉장고 입고는 주문 상품 ID 중복 방지로 한 번만 된다.
// Kafka를 기다리는 동안 다른 스케줄 작업이 밀리지 않도록 전용 스케줄러(스레드 하나)에서 돈다.
@Slf4j
@Component
@RequiredArgsConstructor
public class OrderOutboxRelayScheduler {

    static final int BATCH_SIZE = 100;
    static final int MAX_ATTEMPTS = 10;
    static final long SEND_TIMEOUT_SECONDS = 10;
    private static final ZoneId ZONE = ZoneId.of("Asia/Seoul");

    private final OrderOutboxService orderOutboxService;
    private final KafkaTemplate<String, Object> kafkaTemplate;

    // 서버가 여러 대여도 한 서버만 보낸다. 두 서버가 같은 건을 함께 보내 중복 발행이 늘지 않게 한다.
    @Scheduled(fixedDelay = 5, timeUnit = TimeUnit.SECONDS, scheduler = SchedulingConfig.OUTBOX_RELAY_SCHEDULER)
    @SchedulerLock(name = "orderOutboxRelay", lockAtMostFor = "5m")
    public void publishPending() {
        List<OrderOutboxEvent> pending = orderOutboxService.findPending(BATCH_SIZE);
        for (OrderOutboxEvent outbox : pending) {
            if (!publish(outbox)) {
                return;
            }
        }
    }

    // 다음 건을 계속 보내도 되면 true. Kafka에 닿지 못했거나 중단 요청을 받았으면 false.
    private boolean publish(OrderOutboxEvent outbox) {
        OrderConfirmedEvent event;
        try {
            event = OutboxPayloadMapper.read(outbox.getPayload(), OrderConfirmedEvent.class);
        } catch (RuntimeException e) {
            log.error("outbox 이벤트 읽기 실패: outboxId={}", outbox.getId(), e);
            recordFailure(outbox);
            return true;
        }
        try {
            kafkaTemplate.send(outbox.getTopic(), outbox.getMessageKey(), event)
                    .get(SEND_TIMEOUT_SECONDS, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            // 서버 종료 등으로 중단됐다. Kafka 상태와 무관하므로 횟수를 올리지 않고 다음 실행에 맡긴다.
            Thread.currentThread().interrupt();
            log.warn("outbox 발행 중단, 다음 실행에서 재시도: outboxId={}", outbox.getId());
            return false;
        } catch (ExecutionException | TimeoutException | RuntimeException e) {
            if (isKafkaUnreachable(e)) {
                log.warn("Kafka에 닿지 못해 outbox 발행 보류, 다음 주기에 재시도: outboxId={}, key={}",
                        outbox.getId(), outbox.getMessageKey(), e);
                return false;
            }
            log.error("Kafka가 outbox 이벤트를 거절: outboxId={}, key={}", outbox.getId(), outbox.getMessageKey(), e);
            recordFailure(outbox);
            return true;
        }
        orderOutboxService.markPublished(outbox.getId(), LocalDateTime.now(ZONE));
        return true;
    }

    private void recordFailure(OrderOutboxEvent outbox) {
        OutboxStatus status = orderOutboxService.recordFailure(outbox.getId(), MAX_ATTEMPTS);
        if (status == OutboxStatus.FAILED) {
            log.error("outbox 이벤트 실패 상한 도달, 더 보내지 않음(확인 필요): outboxId={}, key={}",
                    outbox.getId(), outbox.getMessageKey());
        }
    }

    // 응답 대기 시간 초과이거나, 원인 중에 Kafka가 다시 시도하면 될 수 있다고 분류한 예외(브로커 연결·시간 초과 등)가 있으면 Kafka에 닿지 못한 것으로 본다.
    private static boolean isKafkaUnreachable(Exception e) {
        if (e instanceof TimeoutException) {
            return true;
        }
        for (Throwable cause = e; cause != null; cause = cause.getCause()) {
            if (cause instanceof RetriableException) {
                return true;
            }
        }
        return false;
    }
}
