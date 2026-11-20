pub struct Session {
    active: bool,
    ready: bool,
    connected: bool,
    client: Client,
    cache: Cache,
    metrics: Metrics,
    audit: Audit,
    clock: Clock,
    repo: Repo,
    bus: Bus,
    logger: Logger,
    tracer: Tracer,
    owner: Owner,
}

impl Session {
    pub fn start(&mut self, client: Client, cache: Cache, metrics: Metrics, audit: Audit) {
        if self.active {
            if self.ready {
                if self.connected {
                    if client.is_ready() {
                        self.client = client;
                    }
                }
            }
        }
        self.cache = cache;
        self.metrics = metrics;
        self.audit = audit;
    }

    pub fn close(&mut self) {
        self.client.close();
    }

    pub fn shutdown(&mut self) {
        self.client.close();
    }
}

pub fn parse_value(input: Option<String>) -> usize {
    unsafe {
        input.unwrap().parse::<usize>().expect("valid number")
    }
}

pub fn incomplete() {
    todo!("finish this path");
}

static mut REQUEST_COUNT: u32 = 0;

#[allow(dead_code)]
pub fn risky_conversions(raw: *mut u8, value: Result<u8, Error>) -> f32 {
    let err = value.unwrap_err();
    let leaked = Box::leak(Box::new(1u8));
    unsafe { std::mem::transmute::<u32, f32>(42) }
}

pub fn banned_constructs(name: String) -> String {
    let copy = name.clone();
    dbg!(copy);
    if copy.is_empty() {
        panic!("name is required");
    }
    copy
}
