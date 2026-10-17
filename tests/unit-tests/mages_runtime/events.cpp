#include <catch2/catch_test_macros.hpp>
#include "events.h"
#include "workqueue.h"
#include <set>
#include <string>
#include <thread>
#include <vector>
#include <stdexcept>

using namespace Impacto;

TEST_CASE("MAGES host queues input without an SDL runtime") {
    Events::Reset();
    const auto completed = Events::Register();
    SDL_Event key{};
    key.type = SDL_EVENT_KEY_DOWN;
    key.key.scancode = SDL_SCANCODE_RETURN;
    REQUIRE(Events::Push(&key));
    int payload = 42;
    SDL_Event work{};
    work.type = completed;
    work.user.data1 = &payload;
    REQUIRE(Events::Push(&work));
    SDL_Event event{};
    REQUIRE(Events::PollType(&event, completed));
    CHECK(event.user.data1 == &payload);
    CHECK(event.common.timestamp > 0);
    CHECK_FALSE(Events::PollType(&event, completed));
    REQUIRE(Events::Poll(&event));
    CHECK(event.key.scancode == SDL_SCANCODE_RETURN);
    CHECK_FALSE(Events::Poll(&event));
}

TEST_CASE("MAGES text events own UTF-8 payloads across concurrent producers") {
    Events::Reset();
    std::vector<std::thread> producers;
    for (int producer = 0; producer < 4; ++producer) {
        producers.emplace_back([producer] {
            for (int i = 0; i < 100; ++i) {
                std::string text = std::to_string(producer * 100 + i) +
                    "：一段超过旧输入缓冲区长度的中文粘贴文本";
                SDL_Event event{};
                event.type = SDL_EVENT_TEXT_INPUT;
                event.text.text = text.c_str();
                Events::Push(&event);
                text.assign("overwritten");
            }
        });
    }
    for (auto& producer : producers) producer.join();
    std::set<std::string> texts;
    SDL_Event event{};
    while (Events::Poll(&event)) texts.emplace(event.text.text);
    REQUIRE(texts.size() == 400);
    for (int i = 0; i < 400; ++i)
        CHECK(texts.count(std::to_string(i) + "：一段超过旧输入缓冲区长度的中文粘贴文本") == 1);
    Events::Push(&event);
    Events::Reset();
    CHECK_FALSE(Events::Poll(&event));
    CHECK(Events::Register() == SDL_EVENT_USER);
}

TEST_CASE("MAGES loaders complete on the engine thread before shutdown and restart") {
    struct Ticket {
        bool loaded = false;
        int completed = 0;
        std::thread::id completionThread;
    };
    for (int session = 0; session < 3; ++session) {
        Events::Reset();
        WorkQueue::Init();
        std::vector<Ticket> tickets(64);
        for (auto& ticket : tickets) {
            WorkQueue::Push(&ticket,
                [](void* data) { static_cast<Ticket*>(data)->loaded = true; },
                [](void* data) {
                    auto& ticket = *static_cast<Ticket*>(data);
                    ++ticket.completed;
                    ticket.completionThread = std::this_thread::get_id();
                });
        }
        SDL_Event key{};
        key.type = SDL_EVENT_KEY_DOWN;
        Events::Push(&key);
        WorkQueue::StopWorkQueue();
        for (auto& ticket : tickets) {
            CHECK(ticket.loaded);
            CHECK(ticket.completed == 1);
            CHECK(ticket.completionThread == std::this_thread::get_id());
        }
        SDL_Event event{};
        REQUIRE(Events::Poll(&event));
        CHECK(event.type == SDL_EVENT_KEY_DOWN);
        CHECK_FALSE(Events::Poll(&event));
        WorkQueue::StopWorkQueue();
    }
}

TEST_CASE("MAGES loader failures return to the engine and drain remaining completions") {
    Events::Reset();
    WorkQueue::Init();
    WorkQueue::Push(nullptr,
        [](void*) { throw std::runtime_error("invalid resource"); },
        [](void*) { FAIL("Failed loader must not publish a completed resource"); });
    int completed = 0;
    WorkQueue::Push(&completed, [](void*) {},
        [](void* data) { ++*static_cast<int*>(data); });
    CHECK_THROWS_AS(WorkQueue::StopWorkQueue(), std::runtime_error);
    CHECK(completed == 1);
    CHECK_NOTHROW(WorkQueue::StopWorkQueue());
    WorkQueue::Init();
    WorkQueue::Push(&completed, [](void*) {},
        [](void* data) { ++*static_cast<int*>(data); });
    CHECK_NOTHROW(WorkQueue::StopWorkQueue());
    CHECK(completed == 2);
}
