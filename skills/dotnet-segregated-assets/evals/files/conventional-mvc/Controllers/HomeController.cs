using Microsoft.AspNetCore.Mvc;

namespace Contoso.Web.Controllers;

public sealed class HomeController : Controller
{
    public IActionResult Index() => View();
}
