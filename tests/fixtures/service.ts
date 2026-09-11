import type { Request, Response } from "express";

type Id = string & { readonly __brand: "Id" };

export class HttpError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

function injectable(): ClassDecorator {
  return (target) => {
    Reflect.defineMetadata("injectable", true, target);
  };
}

@injectable()
export class UserService {
  readonly #cache = new Map<Id, User>();

  constructor(private readonly db: Database) {}

  async findById(id: Id): Promise<User | undefined> {
    const cached = this.#cache.get(id);
    if (cached) {
      return cached;
    }
    try {
      const row = await this.db.query<User>("select * from users where id = $1", [id]);
      if (row) this.#cache.set(id, row);
      return row;
    } catch (error) {
      throw new HttpError(500, `lookup failed: ${String(error)}`);
    }
  }

  #invalidate(id: Id): void {
    this.#cache.delete(id);
  }

  static create(db: Database): UserService {
    return new UserService(db);
  }
}

export async function handle(req: Request, res: Response): Promise<void> {
  const service = UserService.create(req.app.locals.db);
  const user = await service.findById(req.params.id as Id);
  res.status(user ? 200 : 404).json(user ?? { error: "not found" });
}

export const middleware = [
  (req: Request, _res: Response, next: () => void) => {
    console.info(req.method, req.url);
    next();
  },
];

interface User {
  id: Id;
  email: string;
}

interface Database {
  query<T>(sql: string, params: unknown[]): Promise<T | undefined>;
}
