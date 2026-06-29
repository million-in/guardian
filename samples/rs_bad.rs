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
