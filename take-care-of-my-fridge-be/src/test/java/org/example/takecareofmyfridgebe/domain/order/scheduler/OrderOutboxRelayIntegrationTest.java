package org.example.takecareofmyfridgebe.domain.order.scheduler;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.serialization.StringSerializer;
import org.example.takecareofmyfridgebe.domain.order.entity.OrderOutboxEvent;
import org.example.takecareofmyfridgebe.domain.order.entity.OutboxStatus;
import org.example.takecareofmyfridgebe.domain.order.event.OrderConfirmedEvent;
import org.example.takecareofmyfridgebe.domain.order.event.OutboxPayloadMapper;
import org.example.takecareofmyfridgebe.domain.order.repository.OrderOutboxEventRepository;
import org.example.takecareofmyfridgebe.domain.order.service.OrderOutboxService;
import org.example.takecareofmyfridgebe.global.config.jpa.JpaAuditingConfig;
import org.example.takecareofmyfridgebe.global.config.jpa.QueryDslConfig;
import org.example.takecareofmyfridgebe.global.config.kafka.KafkaConfig;
import org.example.takecareofmyfridgebe.global.config.kafka.KafkaTopics;
import org.example.takecareofmyfridgebe.support.KafkaContainerSupport;
import org.example.takecareofmyfridgebe.support.MySqlContainerSupport;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest;
import org.springframework.boot.jdbc.test.autoconfigure.AutoConfigureTestDatabase;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.serializer.JacksonJsonSerializer;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

// 실제 MySQL에 저장된 outbox를 실제 Kafka로 보내고, 받는 쪽이 보게 될 그대로(키와 JSON 원문) 도착하는지,
// outbox 상태가 Kafka 응답에 맞춰 바뀌는지 DB를 다시 읽어 확인한다.
// Kafka가 멈춘 상황은 닫힌 포트를 가리키는 KafkaTemplate으로 만든다.
// 공유 Kafka 컨테이너의 같은 토픽에 다른 테스트의 메시지도 있어 이 테스트가 쓰는 주문 ID 키만 본다.
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import({JpaAuditingConfig.class, QueryDslConfig.class, KafkaConfig.class, OrderOutboxService.class,
    OrderOutboxRelayScheduler.class, OrderOutboxRelayIntegrationTest.TestConsumerConfig.class})
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class OrderOutboxRelayIntegrationTest extends MySqlContainerSupport {

    private static final long WAIT_SECONDS = 15;
    private static final LocalDateTime CONFIRMED_AT = LocalDateTime.of(2026, 10, 30, 14, 30, 5);

    // MySQL은 상속으로 받으므로 Kafka는 주소만 넣는다
    @DynamicPropertySource
    static void kafkaProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.kafka.bootstrap-servers", KafkaContainerSupport::bootstrapServers);
    }

    private final OrderOutboxRelayScheduler scheduler;
    private final OrderOutboxService orderOutboxService;
    private final OrderOutboxEventRepository outboxRepository;
    private final TestConsumer testConsumer;

    @Autowired
    OrderOutboxRelayIntegrationTest(
        OrderOutboxRelayScheduler scheduler,
        OrderOutboxService orderOutboxService,
        OrderOutboxEventRepository outboxRepository,
        TestConsumer testConsumer
    ) {
        this.scheduler = scheduler;
        this.orderOutboxService = orderOutboxService;
        this.outboxRepository = outboxRepository;
        this.testConsumer = testConsumer;
    }

    @AfterEach
    void cleanUp() {
        outboxRepository.deleteAll();
    }

    @Test
    @DisplayName("대기 outbox를 보내면 주문 ID를 키로 원래 구매 확정 이벤트 형식 그대로 도착하고 완료로 바뀐다")
    void sendsInOriginalFormatAndMarksPublished() throws InterruptedException {
        OrderOutboxEvent outbox = saveOutbox(new OrderConfirmedEvent(880001L, 7L, CONFIRMED_AT, List.of(
            new OrderConfirmedEvent.Item(11L, 3L, "대파", 2),
            new OrderConfirmedEvent.Item(12L, 4L, "두부", 1))));

        scheduler.publishPending();

        ConsumerRecord<String, String> record = pollByKey("880001");
        assertThat(record).isNotNull();
        JsonNode body = JsonMapper.builder().build().readTree(record.value());
        assertThat(body.isObject()).isTrue();
        assertThat(body.get("orderId").asLong()).isEqualTo(880001L);
        assertThat(body.get("memberId").asLong()).isEqualTo(7L);
        assertThat(body.get("confirmedAt").asString()).isEqualTo("2026-10-30T14:30:05");
        JsonNode items = body.get("items");
        assertThat(items).hasSize(2);
        assertThat(items.get(0).get("orderItemId").asLong()).isEqualTo(11L);
        assertThat(items.get(0).get("productId").asLong()).isEqualTo(3L);
        assertThat(items.get(0).get("productName").asString()).isEqualTo("대파");
        assertThat(items.get(0).get("confirmedQuantity").asInt()).isEqualTo(2);
        assertThat(items.get(1).get("orderItemId").asLong()).isEqualTo(12L);

        OrderOutboxEvent published = reload(outbox);
        assertThat(published.getStatus()).isEqualTo(OutboxStatus.PUBLISHED);
        assertThat(published.getPublishedAt()).isNotNull();
        assertThat(published.getAttemptCount()).isZero();
    }

    @Test
    @DisplayName("Kafka가 멈춘 동안에는 실패 횟수 없이 대기 상태로 남고, 복구된 뒤 다음 주기에 보내 완료로 바뀐다")
    void staysPendingWhileKafkaIsDown_andPublishesAfterRecovery() throws InterruptedException {
        OrderOutboxEvent outbox = saveOutbox(new OrderConfirmedEvent(880002L, 7L, CONFIRMED_AT, List.of(
            new OrderConfirmedEvent.Item(21L, 3L, "대파", 1))));
        DefaultKafkaProducerFactory<String, Object> deadProducerFactory = deadProducerFactory();
        try {
            new OrderOutboxRelayScheduler(orderOutboxService, new KafkaTemplate<>(deadProducerFactory)).publishPending();
        } finally {
            deadProducerFactory.destroy();
        }

        OrderOutboxEvent pending = reload(outbox);
        assertThat(pending.getStatus()).isEqualTo(OutboxStatus.PENDING);
        assertThat(pending.getAttemptCount()).isZero();
        assertThat(pending.getPublishedAt()).isNull();

        scheduler.publishPending();

        assertThat(pollByKey("880002")).isNotNull();
        OrderOutboxEvent published = reload(outbox);
        assertThat(published.getStatus()).isEqualTo(OutboxStatus.PUBLISHED);
        assertThat(published.getPublishedAt()).isNotNull();
    }

    private OrderOutboxEvent saveOutbox(OrderConfirmedEvent event) {
        return outboxRepository.save(OrderOutboxEvent.builder()
            .topic(KafkaTopics.PURCHASE_CONFIRMED)
            .messageKey(String.valueOf(event.orderId()))
            .payload(OutboxPayloadMapper.write(event))
            .build());
    }

    private OrderOutboxEvent reload(OrderOutboxEvent outbox) {
        return outboxRepository.findById(outbox.getId()).orElseThrow();
    }

    // 아무도 듣지 않는 포트를 가리켜 Kafka가 멈춘 상황을 만든다. 기다리는 시간을 짧게 둬 테스트가 오래 걸리지 않게 한다
    private static DefaultKafkaProducerFactory<String, Object> deadProducerFactory() {
        Map<String, Object> props = new HashMap<>();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:1");
        props.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, 1000);
        props.put(ProducerConfig.REQUEST_TIMEOUT_MS_CONFIG, 1000);
        props.put(ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG, 2000);
        JacksonJsonSerializer<Object> valueSerializer = new JacksonJsonSerializer<>();
        valueSerializer.setAddTypeInfo(false);
        return new DefaultKafkaProducerFactory<>(props, new StringSerializer(), valueSerializer);
    }

    private ConsumerRecord<String, String> pollByKey(String key) throws InterruptedException {
        long deadline = System.currentTimeMillis() + WAIT_SECONDS * 1000;
        while (System.currentTimeMillis() < deadline) {
            ConsumerRecord<String, String> record = testConsumer.records.poll(200, TimeUnit.MILLISECONDS);
            if (record != null && key.equals(record.key())) {
                return record;
            }
        }
        return null;
    }

    @TestConfiguration
    static class TestConsumerConfig {

        @Bean
        TestConsumer testConsumer() {
            return new TestConsumer();
        }
    }

    static class TestConsumer {

        final BlockingQueue<ConsumerRecord<String, String>> records = new LinkedBlockingQueue<>();

        @KafkaListener(topics = KafkaTopics.PURCHASE_CONFIRMED, groupId = "test-group-order-outbox-relay")
        void receive(ConsumerRecord<String, String> record) {
            records.offer(record);
        }
    }
}
