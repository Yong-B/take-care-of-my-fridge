package org.example.takecareofmyfridgebe.domain.order.scheduler;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

import java.time.LocalDateTime;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.errors.RecordTooLargeException;
import org.apache.kafka.common.errors.TimeoutException;
import org.example.takecareofmyfridgebe.domain.order.entity.OrderOutboxEvent;
import org.example.takecareofmyfridgebe.domain.order.entity.OutboxStatus;
import org.example.takecareofmyfridgebe.domain.order.event.OrderConfirmedEvent;
import org.example.takecareofmyfridgebe.domain.order.event.OutboxPayloadMapper;
import org.example.takecareofmyfridgebe.domain.order.service.OrderOutboxService;
import org.example.takecareofmyfridgebe.global.config.kafka.KafkaTopics;
import org.example.takecareofmyfridgebe.global.config.scheduling.SchedulingConfig;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.test.util.ReflectionTestUtils;

class OrderOutboxRelaySchedulerTest {

    private final OrderOutboxService orderOutboxService = mock(OrderOutboxService.class);
    @SuppressWarnings("unchecked")
    private final KafkaTemplate<String, Object> kafkaTemplate = mock(KafkaTemplate.class);
    private final OrderOutboxRelayScheduler scheduler = new OrderOutboxRelayScheduler(orderOutboxService, kafkaTemplate);

    @Test
    @DisplayName("대기 outbox를 원래 이벤트 record로 되돌려 주문 ID 키로 보내고 Kafka 응답을 받은 뒤 완료로 표시한다")
    void sendsOriginalEventAndMarksPublished_whenKafkaAcks() {
        OrderConfirmedEvent event = event(100L);
        given(orderOutboxService.findPending(OrderOutboxRelayScheduler.BATCH_SIZE)).willReturn(List.of(outbox(1L, event)));
        given(kafkaTemplate.send(anyString(), anyString(), any())).willReturn(acked());

        scheduler.publishPending();

        ArgumentCaptor<Object> sent = ArgumentCaptor.forClass(Object.class);
        verify(kafkaTemplate).send(eq(KafkaTopics.PURCHASE_CONFIRMED), eq("100"), sent.capture());
        assertThat(sent.getValue()).isEqualTo(event);
        verify(orderOutboxService).markPublished(eq(1L), any(LocalDateTime.class));
        verify(orderOutboxService, never()).recordFailure(anyLong(), anyInt());
    }

    @Test
    @DisplayName("Kafka에 닿지 못하면 실패 횟수를 올리지 않고 완료로 표시하지 않으며 이번 주기의 나머지는 보내지 않는다")
    void keepsPendingWithoutCountingAndStops_whenKafkaIsUnreachable() {
        given(orderOutboxService.findPending(OrderOutboxRelayScheduler.BATCH_SIZE))
            .willReturn(List.of(outbox(1L, event(100L)), outbox(2L, event(101L))));
        given(kafkaTemplate.send(anyString(), anyString(), any()))
            .willReturn(CompletableFuture.failedFuture(new KafkaException("send failed", new TimeoutException("broker down"))));

        scheduler.publishPending();

        verify(orderOutboxService, never()).recordFailure(anyLong(), anyInt());
        verify(orderOutboxService, never()).markPublished(anyLong(), any());
        verify(kafkaTemplate, never()).send(anyString(), eq("101"), any());
    }

    @Test
    @DisplayName("보내기 호출이 메타데이터를 못 받아 바로 예외를 던져도 Kafka에 닿지 못한 것으로 보고 실패 횟수를 올리지 않는다")
    void doesNotCountFailure_whenSendThrowsMetadataTimeout() {
        given(orderOutboxService.findPending(OrderOutboxRelayScheduler.BATCH_SIZE)).willReturn(List.of(outbox(1L, event(100L))));
        given(kafkaTemplate.send(anyString(), anyString(), any())).willThrow(new TimeoutException("metadata timeout"));

        scheduler.publishPending();

        verify(orderOutboxService, never()).recordFailure(anyLong(), anyInt());
        verify(orderOutboxService, never()).markPublished(anyLong(), any());
    }

    @Test
    @DisplayName("Kafka가 이 메시지를 거절하면 실패 횟수를 올리고 다음 건은 계속 보낸다")
    void countsFailureAndContinues_whenKafkaRejectsMessage() {
        given(orderOutboxService.findPending(OrderOutboxRelayScheduler.BATCH_SIZE))
            .willReturn(List.of(outbox(1L, event(100L)), outbox(2L, event(101L))));
        given(orderOutboxService.recordFailure(1L, OrderOutboxRelayScheduler.MAX_ATTEMPTS)).willReturn(OutboxStatus.PENDING);
        given(kafkaTemplate.send(anyString(), eq("100"), any()))
            .willReturn(CompletableFuture.failedFuture(new KafkaException("send failed", new RecordTooLargeException("too large"))));
        given(kafkaTemplate.send(anyString(), eq("101"), any())).willReturn(acked());

        scheduler.publishPending();

        verify(orderOutboxService).recordFailure(1L, OrderOutboxRelayScheduler.MAX_ATTEMPTS);
        verify(orderOutboxService, never()).markPublished(eq(1L), any());
        verify(orderOutboxService).markPublished(eq(2L), any(LocalDateTime.class));
    }

    @Test
    @DisplayName("저장된 내용을 이벤트로 되돌리지 못한 건은 보내지 않고 실패 횟수를 올리며 다음 건은 계속 보낸다")
    void countsFailureAndContinues_whenPayloadIsUnreadable() {
        OrderOutboxEvent broken = outboxWithPayload(1L, "100", "{\"orderId\":");
        given(orderOutboxService.findPending(OrderOutboxRelayScheduler.BATCH_SIZE))
            .willReturn(List.of(broken, outbox(2L, event(101L))));
        given(orderOutboxService.recordFailure(1L, OrderOutboxRelayScheduler.MAX_ATTEMPTS)).willReturn(OutboxStatus.FAILED);
        given(kafkaTemplate.send(anyString(), anyString(), any())).willReturn(acked());

        scheduler.publishPending();

        verify(orderOutboxService).recordFailure(1L, OrderOutboxRelayScheduler.MAX_ATTEMPTS);
        verify(kafkaTemplate, never()).send(anyString(), eq("100"), any());
        verify(orderOutboxService).markPublished(eq(2L), any(LocalDateTime.class));
    }

    @Test
    @DisplayName("대기 outbox가 없으면 아무것도 보내지 않는다")
    void sendsNothing_whenNoPending() {
        given(orderOutboxService.findPending(OrderOutboxRelayScheduler.BATCH_SIZE)).willReturn(List.of());

        scheduler.publishPending();

        verify(kafkaTemplate, never()).send(anyString(), anyString(), any());
    }

    @Test
    @DisplayName("발행 스케줄러는 기본 스케줄러가 아니라 전용 스케줄러에서 돈다")
    void runsOnDedicatedScheduler() throws NoSuchMethodException {
        Scheduled scheduled = OrderOutboxRelayScheduler.class.getMethod("publishPending").getAnnotation(Scheduled.class);

        assertThat(scheduled.scheduler()).isEqualTo(SchedulingConfig.OUTBOX_RELAY_SCHEDULER);
    }

    private static CompletableFuture<SendResult<String, Object>> acked() {
        return CompletableFuture.completedFuture(mock(SendResult.class));
    }

    private static OrderConfirmedEvent event(Long orderId) {
        return new OrderConfirmedEvent(orderId, 7L, LocalDateTime.of(2026, 10, 30, 14, 30, 5),
            List.of(new OrderConfirmedEvent.Item(11L, 3L, "대파", 2)));
    }

    private static OrderOutboxEvent outbox(Long id, OrderConfirmedEvent event) {
        return outboxWithPayload(id, String.valueOf(event.orderId()), OutboxPayloadMapper.write(event));
    }

    private static OrderOutboxEvent outboxWithPayload(Long id, String key, String payload) {
        OrderOutboxEvent outbox = OrderOutboxEvent.builder()
            .topic(KafkaTopics.PURCHASE_CONFIRMED)
            .messageKey(key)
            .payload(payload)
            .build();
        ReflectionTestUtils.setField(outbox, "id", id);
        return outbox;
    }
}
