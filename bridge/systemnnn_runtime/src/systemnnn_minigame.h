#pragma once

#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace aether::systemnnn::minigame {
// Portable translation of Android MiniGameBoard / GameMiniGamePanel. No VM or
// persistence ownership: host calls GameSession::complete_minigame(index) only
// when take_events().cleared is true. Paint deliberately has no win condition.
enum Type { Puzzle=1, Change, Paint, Cross, Slide, Monte, Pyramid, Golf, Nikaku, Kushi };
enum class Animation { None, Deal, Compact, Refill, RemoveCards, CollectCard, TurnCard, Recycle,
    RevealTiles, ConnectTiles, EraseTiles, FallTiles, ShiftTiles, ReturnTiles };
class Random {
public:
    explicit Random(std::uint64_t seed);
    int next(int bound);
private:
    std::uint64_t seed_;
    unsigned bits(int count);
};
struct BoardState {
    int type=0,columns=0,rows=0;
    std::vector<int> cells,deal_order;
    std::deque<int> stock,waste;
    int selected=-1,held=-1,hint_left=6;
    bool cleared=false,game_over=false;
    Animation animation=Animation::None;
    int frame=0,frame_limit=0,first_dealt=0,turning_card=0;
    std::vector<int> moving_to,erasing,connection,incoming;
};
class Board {
public:
    static constexpr int waste=-2,removed_tile=-3;
    Board(int type,std::uint64_t seed,int tile_width=16,int tile_height=16);
    const BoardState& state() const noexcept {return s_;}
    bool choose(int index);
    bool draw_stock();
    bool show_hint();
    bool dismiss_hint();
    bool hinted(int index) const;
    int hint_alpha() const;
    bool animation_running() const;
    bool press_during_animation();
    void tick(); // One configured game frame, not one millisecond.
    bool exposed(int index) const;
    bool marked(int index) const;
    int waste_card(bool beneath=false) const;
    int deal_progress(int ordinal) const;
    int tile_offset(int index) const;
    int return_offset(int column) const;
    std::string take_sound(); // Click, Good, Bad, or empty.
private:
    friend struct TestAccess;
    BoardState s_;
    Random random_;
    int tile_width_,tile_height_,hint_remaining_=0,redeals_=1;
    std::vector<bool> hint_;
    std::deque<int> orphan_tiles_;
    std::string sound_;
    std::vector<int> shuffle(int size,bool cards);
    void begin(Animation next,int frames);
    void finish_animation();
    bool refill();
    bool in_order(int count) const;
    void reverse_cross(int index);
    bool slide(int index);
    bool golf_matches(int value) const;
    bool pair(int index);
    int value_at(int index) const;
    void remove(int index);
    bool matches(int first,int second) const;
    std::vector<int> connection_path(int a,int b) const;
    bool line(int x,int y,int u,int v,int a,int b) const;
    void start_fall();
    bool has_bottom_gap() const;
    void start_shift();
    void commit_moves();
    void erase_skewer();
    bool start_return();
    int empty_top_rows(int col) const;
    std::vector<int> find_pair() const;
    bool empty() const;
    void check_end();
    bool can_compact() const;
};
struct Rect {
    float x=0,y=0,w=0,h=0;
    bool contains(float px,float py) const {return w>0&&h>0&&px>=x&&py>=y&&px<x+w&&py<y+h;}
};
// Straight RGBA8. Empty images are legal; pieces retain readable fallback art.
struct Image {int width=0,height=0;std::vector<std::uint8_t> rgba;};
struct Assets {
    std::shared_ptr<const Image> first,second,trump,mahjong,exit,congratulations;
    std::vector<std::shared_ptr<const Image>> instructions;
};
// Read ASCII configuration keys from init/minigame.xtx (or decoded FXF).
// index is zero based, just like GameSession::complete_minigame().
struct Options {
    int type=0,index=0,width=800,height=600,frame_ms=20;
    std::uint64_t seed=0;
    std::function<int(std::string_view,int)> number;
};
enum class Pointer { Down, Move, Up, Cancel };
struct Events {
    bool cleared=false,game_over=false,exit=false;
    std::vector<int> sounds; // Zero based system SE; negative configuration is omitted.
};
class Frontend {
public:
    Frontend(Options options,Assets assets={});
    ~Frontend();
    Frontend(Frontend&&) noexcept;
    Frontend& operator=(Frontend&&) noexcept;
    Frontend(const Frontend&)=delete;
    Frontend& operator=(const Frontend&)=delete;
    const Board& board() const;
    const std::vector<Rect>& cells() const;
    Rect stock_area() const;
    Rect waste_area() const;
    Rect exit_area() const;
    int hit(float x,float y) const; // Cell index, Board::waste, -3 stock, -4 hints, -5 exit, -1 none.
    void pointer(Pointer event,float x,float y,int button=0); // 0 left,1 right,2 middle.
    void tick(std::uint32_t elapsed_ms);
    Image render() const;
    Events take_events();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace aether::systemnnn::minigame
